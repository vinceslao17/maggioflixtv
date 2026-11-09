#!/usr/bin/env python3
"""MaggioFlix Live: ponte in sola lettura tra qBittorrent e l'app MaggioFlix.

Legge qBittorrent una volta al secondo (sync/maindata, incrementale) e chiede
a Radarr/Sonarr quale torrent corrisponde a quale film o episodio. All'app
restituisce solo numeri per titolo (TMDB): avanzamento, velocita', tempo che
manca e stato. Niente nomi di torrent, nessun comando.

Risponde solo a chi ha una sessione Seerr valida (header X-Seerr-Session con
il valore del cookie connect.sid), verificata su Seerr e tenuta in cache.

Configurazione tramite variabili d'ambiente (vedi README.md).
Solo libreria standard di Python: nessuna dipendenza.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("maggioflix-live")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


QBIT_URL = env("QBIT_URL").rstrip("/")
QBIT_USER = env("QBIT_USER")
QBIT_PASS = env("QBIT_PASS")
SEERR_URL = env("SEERR_URL").rstrip("/")
PORT = int(env("PORT", "8790") or 8790)
POLL_SECONDS = float(env("POLL_SECONDS", "1") or 1)
MAP_SECONDS = float(env("MAP_SECONDS", "10") or 10)
AUTH_DISABLED = env("AUTH_DISABLED") == "1"  # solo per prove in locale
IMPORT_WINDOW = float(env("IMPORT_WINDOW_MINUTES", "90") or 90) * 60
STICKY_SECONDS = 2 * 24 * 3600  # un torrent abbinato resta abbinato per 2 giorni
QBIT_ETA_INFINITE = 8640000
DONE_WINDOW = 12 * 3600  # torrent finiti da poco: restano nel totale del titolo
PLEX_URL = env("PLEX_URL").rstrip("/")
PLEX_TOKEN = env("PLEX_TOKEN")
PLEX_SECONDS = float(env("PLEX_SECONDS", "5") or 5)
AVAILABLE_WINDOW = float(env("AVAILABLE_WINDOW_HOURS", "6") or 6) * 3600

ARRS = [
    # (tipo, 4K?, url, chiave)
    ("movie", False, env("RADARR_URL").rstrip("/"), env("RADARR_KEY")),
    ("movie", True, env("RADARR4K_URL").rstrip("/"), env("RADARR4K_KEY")),
    ("tv", False, env("SONARR_URL").rstrip("/"), env("SONARR_KEY")),
    ("tv", True, env("SONARR4K_URL").rstrip("/"), env("SONARR4K_KEY")),
]
ARRS = [a for a in ARRS if a[2] and a[3]]

# Stati di qBittorrent -> stati semplici per l'app.
STATE_MAP = {
    "downloading": "downloading",
    "forcedDL": "downloading",
    "metaDL": "metadata",
    "forcedMetaDL": "metadata",
    "stalledDL": "stalled",
    "queuedDL": "queued",
    "checkingDL": "checking",
    "checkingResumeData": "checking",
    "allocating": "checking",
    "moving": "checking",
    "pausedDL": "paused",
    "stoppedDL": "paused",
    "error": "error",
    "missingFiles": "error",
}
# Ordine con cui riassumere piu' torrent dello stesso titolo.
STATE_PRIORITY = ["downloading", "metadata", "checking", "queued", "stalled", "paused", "error", "importing"]


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.torrents: dict[str, dict] = {}
        self.rid = 0
        self.qbit_ok = False
        self.qbit_error: str | None = None
        self.last_poll = 0.0
        # hash -> {"type", "tmdbId", "tvdbId", "is4k", "inQueue", "seasons", "episodes"}
        self.mapping: dict[str, dict] = {}
        self.last_map = 0.0
        # Ultimo abbinamento riuscito per ogni Radarr/Sonarr: se uno non risponde
        # si tiene quello precedente, cosi' i download non spariscono a tratti.
        self.arr_maps: dict[str, dict[str, dict]] = {}
        self.arr_imports: dict[str, list[dict]] = {}
        self.known: dict[str, tuple[dict, float]] = {}
        self.imports: list[dict] = []
        # Aggiunti di recente su Plex: e' questo che rende un titolo "disponibile".
        self.plex_ok = False
        self.plex_available: list[dict] = []
        self.snapshot: dict | None = None
        self.snapshot_at = 0.0


STATE = State()


# ---------------------------------------------------------------------------
# HTTP verso i servizi del server
# ---------------------------------------------------------------------------

class Qbit:
    """Client minimo per la WebUI di qBittorrent (4.x e 5.x).

    Il cookie di sessione si gestisce a mano: nelle versioni recenti si chiama
    QBT_SID_<porta> e il login puo' rispondere senza testo (204).
    """

    def __init__(self, url: str, user: str, password: str) -> None:
        self.url = url
        self.user = user
        self.password = password
        self.cookie: str | None = None

    def _open(self, req: urllib.request.Request, timeout: float = 10):
        req.add_header("Referer", self.url + "/")
        req.add_header("Origin", self.url)
        if self.cookie:
            req.add_header("Cookie", self.cookie)
        return urllib.request.urlopen(req, timeout=timeout)

    def login(self) -> None:
        self.cookie = None
        if not self.user:
            return  # qBittorrent senza password per la rete locale
        data = urllib.parse.urlencode({"username": self.user, "password": self.password}).encode()
        req = urllib.request.Request(self.url + "/api/v2/auth/login", data=data, method="POST")
        try:
            with self._open(req) as resp:
                body = resp.read().decode(errors="replace").strip()
                cookies = resp.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as e:
            if e.code == 403:
                raise RuntimeError("qBittorrent ha bloccato l'IP del ponte (troppi tentativi falliti): riavvia qbittorrent") from None
            if e.code == 401:
                raise RuntimeError("qBittorrent rifiuta la richiesta (401): controlla 'Host header validation' nella WebUI") from None
            raise
        if body == "Fails.":
            raise RuntimeError("login qBittorrent rifiutato: utente o password sbagliati (QBIT_USER/QBIT_PASS)")
        for raw in cookies:
            pair = raw.split(";", 1)[0].strip()
            name = pair.split("=", 1)[0].upper()
            if "SID" in name and "=" in pair:
                self.cookie = pair
        # Nessun cookie: va bene se qBittorrent non chiede la password a questa rete;
        # lo dice la prima lettura dei dati.

    def get_json(self, path: str):
        for attempt in range(2):
            try:
                with self._open(urllib.request.Request(self.url + path)) as resp:
                    return json.loads(resp.read() or b"null")
            except urllib.error.HTTPError as e:
                if e.code in (401, 403) and attempt == 0:
                    self.login()
                    continue
                if e.code in (401, 403):
                    raise RuntimeError(
                        "qBittorrent non accetta il login del ponte: controlla QBIT_USER/QBIT_PASS"
                    ) from None
                raise
        return None


def arr_get(url: str, key: str, path: str, timeout: float = 30):
    req = urllib.request.Request(url + path, headers={"X-Api-Key": key, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"null")


# ---------------------------------------------------------------------------
# Cicli in background
# ---------------------------------------------------------------------------

def poll_qbit() -> None:
    qbit = Qbit(QBIT_URL, QBIT_USER, QBIT_PASS)
    backoff = POLL_SECONDS
    logged_in = False
    while True:
        try:
            if not logged_in:
                qbit.login()
                logged_in = True
            data = qbit.get_json(f"/api/v2/sync/maindata?rid={STATE.rid}") or {}
            with STATE.lock:
                if data.get("full_update"):
                    STATE.torrents = {}
                for h, t in (data.get("torrents") or {}).items():
                    STATE.torrents.setdefault(h.lower(), {}).update(t)
                for h in data.get("torrents_removed") or []:
                    STATE.torrents.pop(h.lower(), None)
                STATE.rid = data.get("rid", STATE.rid)
                if not STATE.qbit_ok:
                    log.info("qBittorrent collegato (%d torrent)", len(STATE.torrents))
                STATE.qbit_ok = True
                STATE.qbit_error = None
                STATE.last_poll = time.time()
            backoff = POLL_SECONDS
        except Exception as e:  # noqa: BLE001 - qualsiasi errore: riprova
            message = f"{type(e).__name__}: {e}" if not isinstance(e, RuntimeError) else str(e)
            with STATE.lock:
                # Si scrive nel log ogni errore nuovo (anche il primo), senza ripeterlo.
                if STATE.qbit_ok or message != STATE.qbit_error:
                    log.warning("qBittorrent non raggiungibile (%s): %s", QBIT_URL, message)
                STATE.qbit_ok = False
                STATE.qbit_error = message
                STATE.rid = 0
            logged_in = False
            backoff = min(backoff * 2, 30)
        time.sleep(backoff)


def _int(v) -> int | None:
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _records(payload) -> list:
    if isinstance(payload, dict):
        return payload.get("records") or []
    return payload if isinstance(payload, list) else []


def _when(value) -> float | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def map_instance(kind: str, is4k: bool, url: str, key: str) -> tuple[dict[str, dict], list[dict]]:
    """Abbinamenti hash -> titolo e importazioni recenti di un Radarr/Sonarr."""
    mapping: dict[str, dict] = {}
    imports: list[dict] = []

    def add(download_id, tmdb, tvdb, in_queue, season=None, episode=None):
        if not download_id or not (tmdb or tvdb):
            return
        h = str(download_id).lower()
        m = mapping.setdefault(
            h,
            {"type": kind, "tmdbId": tmdb or None, "tvdbId": tvdb or None, "is4k": is4k, "inQueue": False,
             "seasons": set(), "episodes": set()},
        )
        m["inQueue"] = m["inQueue"] or in_queue
        if season is not None:
            m["seasons"].add(season)
            if episode is not None:
                m["episodes"].add((season, episode))

    now = time.time()
    if kind == "movie":
        queue = arr_get(url, key, "/api/v3/queue?page=1&pageSize=500&includeMovie=true")
        grabbed = arr_get(
            url, key,
            "/api/v3/history?page=1&pageSize=200&sortKey=date&sortDirection=descending&eventType=1&includeMovie=true",
        )
        imported = arr_get(
            url, key,
            "/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&eventType=3&includeMovie=true",
        )
        for in_queue, rows in ((True, _records(queue)), (False, _records(grabbed))):
            for r in rows:
                movie = r.get("movie") or {}
                add(r.get("downloadId"), _int(movie.get("tmdbId")), None, in_queue)
        for r in _records(imported):
            at = _when(r.get("date"))
            movie = r.get("movie") or {}
            if at and now - at < IMPORT_WINDOW and movie.get("tmdbId"):
                imports.append({"type": "movie", "tmdbId": _int(movie.get("tmdbId")), "tvdbId": None, "is4k": is4k,
                                "at": at, "episode": None, "hash": str(r.get("downloadId") or "").lower()})
    else:
        queue = arr_get(url, key, "/api/v3/queue?page=1&pageSize=1000&includeSeries=true&includeEpisode=true")
        grabbed = arr_get(
            url, key,
            "/api/v3/history?page=1&pageSize=400&sortKey=date&sortDirection=descending"
            "&eventType=1&includeSeries=true&includeEpisode=true",
        )
        imported = arr_get(
            url, key,
            "/api/v3/history?page=1&pageSize=300&sortKey=date&sortDirection=descending"
            "&eventType=3&includeSeries=true&includeEpisode=true",
        )
        for in_queue, rows in ((True, _records(queue)), (False, _records(grabbed))):
            for r in rows:
                series = r.get("series") or {}
                ep = r.get("episode") or {}
                add(
                    r.get("downloadId"), _int(series.get("tmdbId")), _int(series.get("tvdbId")), in_queue,
                    _int(ep.get("seasonNumber")), _int(ep.get("episodeNumber")),
                )
        for r in _records(imported):
            at = _when(r.get("date"))
            series = r.get("series") or {}
            ep = r.get("episode") or {}
            if at and now - at < IMPORT_WINDOW and (series.get("tmdbId") or series.get("tvdbId")):
                imports.append({
                    "type": "tv", "tmdbId": _int(series.get("tmdbId")) or None,
                    "tvdbId": _int(series.get("tvdbId")) or None, "is4k": is4k, "at": at,
                    "episode": (_int(ep.get("seasonNumber")), _int(ep.get("episodeNumber"))),
                    "hash": str(r.get("downloadId") or "").lower(),
                })
    return mapping, imports


# ---------------------------------------------------------------------------
# Plex: cosa e' appena comparso nell'app
# ---------------------------------------------------------------------------

def plex_get(path: str, timeout: float = 15):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(
        f"{PLEX_URL}{path}{sep}X-Plex-Token={urllib.parse.quote(PLEX_TOKEN)}",
        headers={"Accept": "application/json", "X-Plex-Product": "MaggioFlix Live"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


def _guid_ids(item: dict) -> tuple[int | None, int | None]:
    tmdb = tvdb = None
    for g in item.get("Guid") or []:
        gid = str(g.get("id") or "")
        if gid.startswith("tmdb://"):
            tmdb = _int(gid[7:])
        elif gid.startswith("tvdb://"):
            tvdb = _int(gid[7:])
    return tmdb, tvdb


_show_ids: dict[str, tuple[int | None, int | None]] = {}


def _ids_of_show(key) -> tuple[int | None, int | None]:
    key = str(key or "")
    if not key:
        return None, None
    if key not in _show_ids:
        data = plex_get(f"/library/metadata/{key}?includeGuids=1")
        meta = ((data.get("MediaContainer") or {}).get("Metadata") or [{}])[0]
        _show_ids[key] = _guid_ids(meta)
        if len(_show_ids) > 2000:
            _show_ids.clear()
    return _show_ids[key]


def poll_plex() -> None:
    last_error = 0.0
    while True:
        try:
            data = plex_get("/library/recentlyAdded?includeGuids=1&X-Plex-Container-Start=0&X-Plex-Container-Size=80")
            now = time.time()
            available = []
            for it in (data.get("MediaContainer") or {}).get("Metadata") or []:
                added = float(it.get("addedAt") or 0)
                if not added or now - added > AVAILABLE_WINDOW:
                    continue
                kind = it.get("type")
                if kind == "movie":
                    tmdb, tvdb = _guid_ids(it)
                    if tmdb:
                        available.append({"type": "movie", "tmdbId": tmdb, "tvdbId": None, "at": added, "episode": None})
                elif kind in ("episode", "season", "show"):
                    show_key = {"episode": it.get("grandparentRatingKey"), "season": it.get("parentRatingKey")}.get(
                        kind, it.get("ratingKey"))
                    tmdb, tvdb = _ids_of_show(show_key)
                    if not (tmdb or tvdb):
                        continue
                    if kind == "episode":
                        episode = (_int(it.get("parentIndex")), _int(it.get("index")))
                    elif kind == "season":
                        episode = (_int(it.get("index")), None)
                    else:
                        episode = None
                    available.append({"type": "tv", "tmdbId": tmdb, "tvdbId": tvdb, "at": added, "episode": episode})
            with STATE.lock:
                if not STATE.plex_ok:
                    log.info("Plex collegato")
                STATE.plex_ok = True
                STATE.plex_available = available
                STATE.snapshot = None
        except Exception as e:  # noqa: BLE001
            with STATE.lock:
                STATE.plex_ok = False
            if time.time() - last_error > 300:
                log.warning("Plex non raggiungibile (%s): %s", PLEX_URL, e)
                last_error = time.time()
        time.sleep(PLEX_SECONDS)


_arr_errors: dict[str, float] = {}


def poll_mapping() -> None:
    while True:
        for kind, is4k, url, key in ARRS:
            name = f"{kind}{'4k' if is4k else ''}"
            try:
                mapping, imports = map_instance(kind, is4k, url, key)
                with STATE.lock:
                    STATE.arr_maps[name] = mapping
                    STATE.arr_imports[name] = imports

            except Exception as e:  # noqa: BLE001 - si tiene l'abbinamento precedente
                if time.time() - _arr_errors.get(name, 0) > 300:
                    log.warning("%s non raggiungibile (%s): %s", "Radarr" if kind == "movie" else "Sonarr", url, e)
                    _arr_errors[name] = time.time()
        now = time.time()
        with STATE.lock:
            merged: dict[str, dict] = {}
            for mapping in STATE.arr_maps.values():
                for h, m in mapping.items():
                    if h in merged:
                        merged[h]["inQueue"] = merged[h]["inQueue"] or m["inQueue"]
                    else:
                        merged[h] = m
            for h, m in merged.items():
                STATE.known[h] = (m, now)
            for h, (m, seen) in list(STATE.known.items()):
                if now - seen > STICKY_SECONDS:
                    del STATE.known[h]
                elif h not in merged:
                    merged[h] = {**m, "inQueue": False}
            STATE.mapping = merged
            STATE.imports = [i for imports in STATE.arr_imports.values() for i in imports]
            STATE.last_map = now
            STATE.snapshot = None
        time.sleep(MAP_SECONDS)


# ---------------------------------------------------------------------------
# Risposta per l'app
# ---------------------------------------------------------------------------

def build_snapshot() -> dict:
    now = time.time()
    with STATE.lock:
        if STATE.snapshot is not None and now - STATE.snapshot_at < 0.5:
            return STATE.snapshot
        torrents = STATE.torrents
        groups: dict[tuple, dict] = {}
        finished: list[tuple[str, dict, dict]] = []
        for h, m in STATE.mapping.items():
            t = torrents.get(h)
            if not t:
                continue
            progress = min(max(float(t.get("progress") or 0), 0.0), 1.0)
            if progress >= 1:
                if not m["inQueue"]:
                    # Finito e importato: conta nel totale del titolo solo se altri
                    # suoi torrent stanno ancora scaricando (episodi di una stagione),
                    # cosi' la percentuale non torna indietro quando uno finisce.
                    done_at = float(t.get("completion_on") or 0)
                    if done_at > 0 and now - done_at < DONE_WINDOW:
                        finished.append((h, m, t))
                    continue
                state = "importing"
            else:
                state = STATE_MAP.get(t.get("state", ""), "downloading")
            key = (m["type"], m["tmdbId"] or m["tvdbId"], m["is4k"])
            g = groups.setdefault(key, {
                "type": m["type"], "tmdbId": m["tmdbId"], "tvdbId": m["tvdbId"], "is4k": m["is4k"],
                "size": 0, "done": 0.0, "speed": 0, "etas": [], "seeds": 0, "peers": 0, "count": 0,
                "states": [], "seasons": set(), "episodes": set(),
            })
            size = int(t.get("size") or t.get("total_size") or 0)
            g["size"] += size
            # Stessi numeri che mostra qBittorrent: avanzamento, velocita' e ETA suoi.
            g["done"] += progress * size
            if progress < 1:
                g["speed"] += int(t.get("dlspeed") or 0)
                eta = _int(t.get("eta"))
                if state == "downloading" and eta is not None and 0 <= eta < QBIT_ETA_INFINITE:
                    g["etas"].append(eta)
            g["seeds"] += int(t.get("num_seeds") or 0)
            g["peers"] += int(t.get("num_leechs") or 0)
            g["count"] += 1
            g["states"].append(state)
            g["seasons"] |= m["seasons"]
            g["episodes"] |= m["episodes"]

        for h, m, t in finished:
            key = (m["type"], m["tmdbId"] or m["tvdbId"], m["is4k"])
            g = groups.get(key)
            if g is None:
                continue
            size = int(t.get("size") or t.get("total_size") or 0)
            g["size"] += size
            g["done"] += size
            g["count"] += 1
            g["seasons"] |= m["seasons"]
            g["episodes"] |= m["episodes"]

        items = []
        for g in groups.values():
            state = min(g["states"], key=lambda s: STATE_PRIORITY.index(s) if s in STATE_PRIORITY else 99)
            size = g["size"]
            progress = g["done"] / size if size > 0 else 0.0
            left = max(int(size - g["done"]), 0)
            speed = g["speed"]
            eta = max(g["etas"]) if g["etas"] else (int(left / speed) if speed > 0 and left > 0 else None)
            items.append({
                "type": g["type"], "tmdbId": g["tmdbId"], "tvdbId": g["tvdbId"], "is4k": g["is4k"],
                "progress": round(progress, 4), "size": size, "left": left, "speed": speed, "eta": eta,
                "state": state, "seeds": g["seeds"], "peers": g["peers"], "count": g["count"],
                "seasons": sorted(g["seasons"]), "episodes": len(g["episodes"]),
            })

        # Comparsi su Plex da poco: disponibili davvero (vince su tutto, tranne un
        # download ancora in corso dello stesso titolo).
        on_plex: dict[tuple, dict] = {}
        for i in STATE.plex_available:
            for is4k in ((False, True) if i["type"] == "movie" else (False,)):
                key = (i["type"], i["tmdbId"] or i["tvdbId"], is4k)
                if key in groups:
                    continue
                g = on_plex.setdefault(key, {
                    "type": i["type"], "tmdbId": i["tmdbId"], "tvdbId": i["tvdbId"], "is4k": is4k,
                    "at": i["at"], "episodes": set(), "seasons": set(),
                })
                g["at"] = max(g["at"], i["at"])
                ep = i["episode"]
                if ep and ep[0] is not None:
                    g["seasons"].add(ep[0])
                    if ep[1] is not None:
                        g["episodes"].add(ep)
        for g in on_plex.values():
            items.append({
                "type": g["type"], "tmdbId": g["tmdbId"], "tvdbId": g["tvdbId"], "is4k": g["is4k"],
                "progress": 1, "size": 0, "left": 0, "speed": 0, "eta": None, "state": "available",
                "availableAt": int(g["at"] * 1000), "seeds": 0, "peers": 0, "count": 0,
                "seasons": sorted(g["seasons"]), "episodes": len(g["episodes"]),
            })

        # Importati da Radarr/Sonarr ma non ancora su Plex.
        imported: dict[tuple, dict] = {}
        for i in STATE.imports:
            key = (i["type"], i["tmdbId"] or i["tvdbId"], i["is4k"])
            if key in groups or key in on_plex:
                continue
            g = imported.setdefault(key, {
                "type": i["type"], "tmdbId": i["tmdbId"], "tvdbId": i["tvdbId"], "is4k": i["is4k"],
                "at": i["at"], "episodes": set(), "seasons": set(),
            })
            g["at"] = max(g["at"], i["at"])
            if i["episode"] and i["episode"][0] is not None:
                g["seasons"].add(i["episode"][0])
                g["episodes"].add(i["episode"])
        for g in imported.values():
            items.append({
                "type": g["type"], "tmdbId": g["tmdbId"], "tvdbId": g["tvdbId"], "is4k": g["is4k"],
                "progress": 1, "size": 0, "left": 0, "speed": 0, "eta": None, "state": "imported",
                "importedAt": int(g["at"] * 1000), "seeds": 0, "peers": 0, "count": 0,
                "seasons": sorted(g["seasons"]), "episodes": len(g["episodes"]),
            })

        STATE.snapshot = {
            "version": 3,
            "at": int(now * 1000),
            "qbit": STATE.qbit_ok,
            "plex": bool(PLEX_URL and PLEX_TOKEN and STATE.plex_ok),
            "items": items,
        }
        STATE.snapshot_at = now
        return STATE.snapshot


# ---------------------------------------------------------------------------
# Verifica della sessione Seerr
# ---------------------------------------------------------------------------

_sessions: dict[str, tuple[bool, float]] = {}
_sessions_lock = threading.Lock()


def session_ok(sid: str) -> bool:
    if AUTH_DISABLED:
        return True
    if not sid or len(sid) > 512 or not SEERR_URL:
        return False
    now = time.time()
    with _sessions_lock:
        cached = _sessions.get(sid)
        if cached and cached[1] > now:
            return cached[0]
    ok = False
    try:
        req = urllib.request.Request(
            SEERR_URL + "/api/v1/auth/me",
            headers={"Cookie": f"connect.sid={sid}", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            ok = resp.status == 200 and bool(json.loads(resp.read() or b"{}").get("id"))
    except urllib.error.HTTPError as e:
        ok = False
        if e.code not in (401, 403):
            log.warning("Seerr ha risposto %s alla verifica della sessione", e.code)
            return False  # errore di Seerr: non tenere in cache
    except Exception as e:  # noqa: BLE001
        log.warning("Seerr non raggiungibile per la verifica: %s", e)
        return False
    with _sessions_lock:
        if len(_sessions) > 2000:
            _sessions.clear()
        _sessions[sid] = (ok, now + (600 if ok else 30))
    return ok


# ---------------------------------------------------------------------------
# Calendario e stagioni: letti al momento da Radarr/Sonarr (con una piccola cache)
# ---------------------------------------------------------------------------

_cache: dict[str, tuple[float, object]] = {}
_cache_lock = threading.Lock()


def cached(key: str, ttl: float, fn):
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = fn()
    with _cache_lock:
        if len(_cache) > 200:
            _cache.clear()
        _cache[key] = (now, value)
    return value


def _image(images, cover: str, size: str = "w342") -> str | None:
    for img in images or []:
        if img.get("coverType") == cover:
            url = img.get("remoteUrl") or ""
            if "image.tmdb.org/t/p/original/" in url:
                url = url.replace("/t/p/original/", f"/t/p/{size}/")
            return url or None
    return None


def _date_only(value) -> str | None:
    return str(value)[:10] if value else None


def build_calendar(start: str, end: str) -> dict:
    """Uscite dei film (cinema, digitale, fisico) ed episodi delle serie seguite."""
    items: dict[tuple, dict] = {}
    errors = 0
    query = urllib.parse.urlencode({"start": start, "end": end, "unmonitored": "false"})
    for kind, is4k, url, key in ARRS:
        try:
            if kind == "movie":
                rows = arr_get(url, key, f"/api/v3/calendar?{query}") or []
                for m in rows:
                    tmdb = _int(m.get("tmdbId"))
                    for release, field in (("cinema", "inCinemas"), ("digital", "digitalRelease"),
                                           ("physical", "physicalRelease")):
                        day = _date_only(m.get(field))
                        if not day or not (start <= day <= end):
                            continue
                        k = ("movie", tmdb or m.get("title"), release, day)
                        item = items.get(k)
                        if item is None:
                            items[k] = {
                                "type": "movie", "tmdbId": tmdb, "title": m.get("title") or "",
                                "year": _int(m.get("year")), "date": day, "release": release,
                                "hasFile": bool(m.get("hasFile")),
                                "poster": _image(m.get("images"), "poster"),
                                "fanart": _image(m.get("images"), "fanart", "w780"),
                            }
                        else:
                            item["hasFile"] = item["hasFile"] or bool(m.get("hasFile"))
            else:
                rows = arr_get(url, key, f"/api/v3/calendar?{query}&includeSeries=true") or []
                for e in rows:
                    series = e.get("series") or {}
                    tvdb = _int(series.get("tvdbId"))
                    season = _int(e.get("seasonNumber"))
                    number = _int(e.get("episodeNumber"))
                    k = ("tv", tvdb or series.get("title"), season, number)
                    item = items.get(k)
                    if item is None:
                        items[k] = {
                            "type": "tv", "tmdbId": _int(series.get("tmdbId")) or None, "tvdbId": tvdb,
                            "title": series.get("title") or "", "date": _date_only(e.get("airDate")),
                            "airUtc": e.get("airDateUtc"), "season": season, "episode": number,
                            "episodeTitle": e.get("title") or "", "hasFile": bool(e.get("hasFile")),
                            "finale": e.get("finaleType"), "network": series.get("network"),
                            "poster": _image(series.get("images"), "poster"),
                            "fanart": _image(series.get("images"), "fanart"),
                        }
                    else:
                        item["hasFile"] = item["hasFile"] or bool(e.get("hasFile"))
        except Exception as e:  # noqa: BLE001
            errors += 1
            log.warning("Calendario: %s non raggiungibile: %s", url, e)
    ordered = sorted(items.values(), key=lambda i: (i.get("airUtc") or i.get("date") or "", i.get("title") or ""))
    return {"start": start, "end": end, "items": ordered, "errors": errors}


def _all_series(url: str, key: str) -> list:
    return cached(f"series:{url}", 60, lambda: arr_get(url, key, "/api/v3/series") or [])


def build_series(tmdb: int | None, tvdb: int | None) -> dict:
    """Stagioni di una serie su Sonarr: quanti episodi sono gia' sul server."""
    for kind, is4k, url, key in sorted(ARRS, key=lambda a: a[1]):
        if kind != "tv":
            continue
        try:
            rows = _all_series(url, key)
        except Exception as e:  # noqa: BLE001
            log.warning("Sonarr non raggiungibile (%s): %s", url, e)
            continue
        for s in rows:
            if (tvdb and _int(s.get("tvdbId")) == tvdb) or (tmdb and _int(s.get("tmdbId")) == tmdb):
                seasons = []
                for season in s.get("seasons") or []:
                    stats = season.get("statistics") or {}
                    seasons.append({
                        "season": _int(season.get("seasonNumber")),
                        "monitored": bool(season.get("monitored")),
                        "files": _int(stats.get("episodeFileCount")) or 0,
                        "aired": _int(stats.get("episodeCount")) or 0,
                        "total": _int(stats.get("totalEpisodeCount")) or 0,
                    })
                return {"found": True, "is4k": is4k, "monitored": bool(s.get("monitored")),
                        "tvdbId": _int(s.get("tvdbId")), "tmdbId": _int(s.get("tmdbId")), "seasons": seasons}
    return {"found": False, "seasons": []}


class Handler(BaseHTTPRequestHandler):
    server_version = "MaggioFlixLive/1"

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            with STATE.lock:
                self._send(200, {
                    "ok": STATE.qbit_ok,
                    "qbitError": STATE.qbit_error,
                    "plex": STATE.plex_ok if PLEX_URL else None,
                    "torrents": len(STATE.torrents),
                    "mapped": len(STATE.mapping),
                    "lastPoll": round(time.time() - STATE.last_poll, 1) if STATE.last_poll else None,
                    "lastMap": round(time.time() - STATE.last_map, 1) if STATE.last_map else None,
                })
            return
        if path.startswith("/api/"):
            sid = self.headers.get("X-Seerr-Session", "")
            if not session_ok(sid):
                self._send(401, {"error": "unauthorized"})
                return
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

        def arg(name: str) -> str:
            return (query.get(name) or [""])[0].strip()

        if path == "/api/live":
            self._send(200, build_snapshot())
            return
        if path == "/api/calendar":
            start, end = arg("start")[:10], arg("end")[:10]
            try:
                datetime.strptime(start, "%Y-%m-%d")
                datetime.strptime(end, "%Y-%m-%d")
            except ValueError:
                self._send(400, {"error": "start/end: YYYY-MM-DD"})
                return
            self._send(200, cached(f"cal:{start}:{end}", 120, lambda: build_calendar(start, end)))
            return
        if path == "/api/series":
            tmdb, tvdb = _int(arg("tmdb")), _int(arg("tvdb"))
            if not tmdb and not tvdb:
                self._send(400, {"error": "tmdb o tvdb"})
                return
            self._send(200, build_series(tmdb, tvdb))
            return
        self._send(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:  # silenzio sulle richieste normali
        pass


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not QBIT_URL:
        raise SystemExit("Manca QBIT_URL")
    if not SEERR_URL and not AUTH_DISABLED:
        raise SystemExit("Manca SEERR_URL (serve a verificare chi usa l'app)")
    if not ARRS:
        log.warning("Nessun Radarr/Sonarr configurato: non so abbinare i torrent ai titoli")
    threading.Thread(target=poll_qbit, name="qbit", daemon=True).start()
    threading.Thread(target=poll_mapping, name="arr", daemon=True).start()
    if PLEX_URL and PLEX_TOKEN:
        threading.Thread(target=poll_plex, name="plex", daemon=True).start()
    else:
        log.warning("PLEX_URL/PLEX_TOKEN non impostati: 'disponibile' arrivera' solo da Seerr")
    log.info("MaggioFlix Live in ascolto sulla porta %d (%d Radarr/Sonarr)", PORT, len(ARRS))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
