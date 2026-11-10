#!/usr/bin/env python3
"""Carica l'AAB di MaggioFlix nel test interno di Google Play.

Usa la Google Play Developer API con un account di servizio. La chiave JSON
arriva dal segreto PLAY_SERVICE_ACCOUNT_JSON (non viene mai stampata).

Uso: play_upload.py <file.aab> <nome release> [note]
"""

import json
import os
import sys

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

PACKAGE = os.environ.get("PLAY_PACKAGE", "com.maggioflix.tv")
TRACK = os.environ.get("PLAY_TRACK", "internal")
API = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
UPLOAD = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}"


def fail(step: str, resp: requests.Response) -> None:
    try:
        detail = resp.json().get("error", {}).get("message", resp.text)
    except ValueError:
        detail = resp.text
    sys.exit(f"Google Play: {step} non riuscito (HTTP {resp.status_code}): {detail[:500]}")


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    aab, name = sys.argv[1], sys.argv[2]
    notes = sys.argv[3] if len(sys.argv) > 3 else name

    info = json.loads(os.environ["PLAY_SERVICE_ACCOUNT_JSON"])
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    creds.refresh(Request())
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {creds.token}"

    r = session.post(f"{API}/edits", json={}, timeout=60)
    if not r.ok:
        fail("apertura modifica", r)
    edit = r.json()["id"]

    # Caricamento "resumable": l'AAB pesa centinaia di MB.
    size = os.path.getsize(aab)
    r = session.post(
        f"{UPLOAD}/edits/{edit}/bundles?uploadType=resumable",
        headers={"X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": str(size)},
        timeout=60,
    )
    if not r.ok:
        fail("avvio caricamento", r)
    location = r.headers["Location"]
    with open(aab, "rb") as f:
        r = session.put(location, data=f, headers={"Content-Type": "application/octet-stream"}, timeout=1800)
    if not r.ok:
        fail("caricamento AAB", r)
    version_code = r.json()["versionCode"]
    print(f"AAB caricato: versionCode {version_code}")

    release = {
        "name": name,
        "versionCodes": [str(version_code)],
        "status": "completed",
        "releaseNotes": [{"language": "en-US", "text": notes[:500]}],
    }
    r = session.put(f"{API}/edits/{edit}/tracks/{TRACK}", json={"track": TRACK, "releases": [release]}, timeout=60)
    if not r.ok:
        fail(f"aggiornamento canale {TRACK}", r)

    r = session.post(f"{API}/edits/{edit}:commit", timeout=120)
    if not r.ok:
        fail("pubblicazione", r)
    print(f"{name} pubblicata nel canale '{TRACK}' di Google Play.")


if __name__ == "__main__":
    main()
