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

import http.cookiejar
import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
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
        self.last_poll = 0.0
        # hash -> {"type", "tmdbId", "tvdbId", "is4k", "inQueue", "seasons", "episodes"}
        self.mapping: dict[str, dict] = {}
        self.last_map = 0.0
        self.snapshot: dict | None = None
        self.snapshot_at = 0.0


STATE = State()


# ---------------------------------------------------------------------------
# HTTP verso i servizi del server
# ---------------------------------------------------------------------------

class Qbit:
    def __init__(self, url: str, user: str, password: str) -> None:
        self.url = url
        self.user = user
        self.password = password
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def _open(self, req: urllib.request.Request, timeout: float = 10):
        req.add_header("Referer", self.url + "/")
        return self.opener.open(req, timeout=timeout)

    def login(self) -> None:
        if not self.user:
            return  # qBittorrent senza password per la rete locale
        data = urllib.parse.urlencode({"username": self.user, "password": self.password}).encode()
        req = urllib.request.Request(self.url + "/api/v2/auth/login", data=data, method="POST")
        with self._open(req) as resp:
            body = resp.read().decode(errors="replace").strip()
        if body != "Ok.":
            raise RuntimeError(f"login qBittorrent rifiutato: {body!r}")

    def get_json(self, path: str):
        for attempt in range(2):
            try:
                with self._open(urllib.request.Request(self.url + path)) as resp:
                    return json.loads(resp.read() or b"null")
            except urllib.error.HTTPError as e:
                if e.code in (401, 403) and attempt == 0:
                    self.login()
                    continue
                raise
        return None


def arr_get(url: str, key: str, path: str, timeout: float = 15):
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
                STATE.last_poll = time.time()
            backoff = POLL_SECONDS
        except Exception as e:  # noqa: BLE001 - qualsiasi errore: riprova
            with STATE.lock:
                if STATE.qbit_ok:
                    log.warning("qBittorrent non raggiungibile: %s", e)
                STATE.qbit_ok = False
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


def build_mapping() -> dict[str, dict]:
    mapping: dict[str, dict] = {}

    def add(download_id, kind, is4k, tmdb, tvdb, in_queue, season=None, episode=None):
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

    for kind, is4k, url, key in ARRS:
        try:
            if kind == "movie":
                queue = arr_get(url, key, "/api/v3/queue?page=1&pageSize=500&includeMovie=true")
                history = arr_get(
                    url, key,
                    "/api/v3/history?page=1&pageSize=150&sortKey=date&sortDirection=descending"
                    "&eventType=1&includeMovie=true",
                )
                for in_queue, rows in ((True, _records(queue)), (False, _records(history))):
                    for r in rows:
                        movie = r.get("movie") or {}
                        add(r.get("downloadId"), "movie", is4k, _int(movie.get("tmdbId")), None, in_queue)
            else:
                queue = arr_get(url, key, "/api/v3/queue?page=1&pageSize=1000&includeSeries=true&includeEpisode=true")
                history = arr_get(
                    url, key,
                    "/api/v3/history?page=1&pageSize=300&sortKey=date&sortDirection=descending"
                    "&eventType=1&includeSeries=true&includeEpisode=true",
                )
                for in_queue, rows in ((True, _records(queue)), (False, _records(history))):
                    for r in rows:
                        series = r.get("series") or {}
                        ep = r.get("episode") or {}
                        add(
                            r.get("downloadId"), "tv", is4k,
                            _int(series.get("tmdbId")), _int(series.get("tvdbId")), in_queue,
                            _int(ep.get("seasonNumber")), _int(ep.get("episodeNumber")),
                        )
        except Exception as e:  # noqa: BLE001
            log.warning("%s non raggiungibile (%s): %s", "Radarr" if kind == "movie" else "Sonarr", url, e)
    return mapping


def poll_mapping() -> None:
    while True:
        try:
            mapping = build_mapping()
            with STATE.lock:
                STATE.mapping = mapping
                STATE.last_map = time.time()
        except Exception as e:  # noqa: BLE001
            log.warning("abbinamento torrent fallito: %s", e)
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
        for h, m in STATE.mapping.items():
            t = torrents.get(h)
            if not t:
                continue
            progress = float(t.get("progress") or 0)
            if progress >= 1:
                if not m["inQueue"]:
                    continue  # finito e gia' importato
                state = "importing"
            else:
                state = STATE_MAP.get(t.get("state", ""), "downloading")
            ident = m["tmdbId"] or m["tvdbId"]
            key = (m["type"], ident, m["is4k"])
            g = groups.setdefault(key, {
                "type": m["type"], "tmdbId": m["tmdbId"], "tvdbId": m["tvdbId"], "is4k": m["is4k"],
                "size": 0, "left": 0, "speed": 0, "seeds": 0, "peers": 0, "count": 0,
                "states": [], "seasons": set(), "episodes": set(),
            })
            size = int(t.get("size") or t.get("total_size") or 0)
            left = int(t.get("amount_left") or 0) if progress < 1 else 0
            g["size"] += size
            g["left"] += left
            g["speed"] += int(t.get("dlspeed") or 0) if progress < 1 else 0
            g["seeds"] += int(t.get("num_seeds") or 0)
            g["peers"] += int(t.get("num_leechs") or 0)
            g["count"] += 1
            g["states"].append(state)
            g["seasons"] |= m["seasons"]
            g["episodes"] |= m["episodes"]

        items = []
        for g in groups.values():
            state = min(g["states"], key=lambda s: STATE_PRIORITY.index(s) if s in STATE_PRIORITY else 99)
            size, left, speed = g["size"], g["left"], g["speed"]
            items.append({
                "type": g["type"],
                "tmdbId": g["tmdbId"],
                "tvdbId": g["tvdbId"],
                "is4k": g["is4k"],
                "progress": round(1 - left / size, 4) if size > 0 else 0,
                "size": size,
                "left": left,
                "speed": speed,
                "eta": int(left / speed) if speed > 0 and left > 0 else None,
                "state": state,
                "seeds": g["seeds"],
                "peers": g["peers"],
                "count": g["count"],
                "seasons": sorted(g["seasons"]),
                "episodes": len(g["episodes"]),
            })
        STATE.snapshot = {
            "version": 1,
            "at": int(now * 1000),
            "qbit": STATE.qbit_ok,
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
                    "torrents": len(STATE.torrents),
                    "mapped": len(STATE.mapping),
                    "lastPoll": round(time.time() - STATE.last_poll, 1) if STATE.last_poll else None,
                    "lastMap": round(time.time() - STATE.last_map, 1) if STATE.last_map else None,
                })
            return
        if path == "/api/live":
            sid = self.headers.get("X-Seerr-Session", "")
            if not session_ok(sid):
                self._send(401, {"error": "unauthorized"})
                return
            self._send(200, build_snapshot())
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
    log.info("MaggioFlix Live in ascolto sulla porta %d (%d Radarr/Sonarr)", PORT, len(ARRS))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
