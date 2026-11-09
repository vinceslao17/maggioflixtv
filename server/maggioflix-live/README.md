# MaggioFlix Live

Ponte in sola lettura tra qBittorrent e l'app MaggioFlix: avanzamento, velocità e
tempo che manca dei download, aggiornati ogni secondo.

- Legge qBittorrent una volta al secondo (`/api/v2/sync/maindata`, incrementale).
- Chiede a Radarr/Sonarr (coda e storico dei "grabbed") quale torrent è quale film o
  episodio, ogni 10 secondi.
- Usa i numeri di qBittorrent così come sono (avanzamento, velocità, ETA).
- Se Radarr/Sonarr non rispondono per un attimo tiene l'ultimo abbinamento; un torrent
  abbinato resta abbinato per 2 giorni.
- Segnala anche i titoli importati da poco (ultimi 90 minuti) con stato `imported`,
  così l'app sa che sono sul server prima che lo dica Seerr.
- All'app manda solo numeri per titolo (TMDB/TVDB): niente nomi di torrent, nessun comando.
- Risponde solo a chi ha una sessione Seerr valida (header `X-Seerr-Session`).

## Endpoint

- `GET /health` — stato del collegamento a qBittorrent (senza login).
- `GET /api/live` — download in corso, con header `X-Seerr-Session: <valore di connect.sid>`.

## Variabili

| Variabile | Esempio | Note |
|---|---|---|
| `QBIT_URL` | `http://gluetun:8080` | WebUI di qBittorrent |
| `QBIT_USER`, `QBIT_PASS` | | credenziali della WebUI |
| `RADARR_URL`, `RADARR_KEY` | `http://radarr:7878` | Impostazioni → Generali → Chiave API |
| `RADARR4K_URL`, `RADARR4K_KEY` | | facoltativo |
| `SONARR_URL`, `SONARR_KEY` | `http://sonarr:8989` | |
| `SEERR_URL` | `http://seerr:5055` | per verificare le sessioni dell'app |
| `PORT` | `8790` | porta interna |

Pubblicazione: nel tunnel Cloudflare un public hostname `live.maggioflix.com` →
`http://maggioflix-live:8790` (il container sta sulla rete `maggio_default`).
