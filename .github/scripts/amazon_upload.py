#!/usr/bin/env python3
"""Carica l'APK di MaggioFlix su Amazon Appstore (App Submission API).

Segreti (mai stampati): AMAZON_CLIENT_ID, AMAZON_CLIENT_SECRET.
Variabile: AMAZON_APP_ID (id dell'app, amzn1.devportal.mobileapp.…).

Attenzione: l'API lavora sulla versione dell'app che va in pubblicazione, non
sul Live App Testing. Con AMAZON_COMMIT=0 (predefinito) l'APK viene solo
caricato nella bozza e non viene inviato: serve il commit per pubblicare.

Uso: amazon_upload.py <file.apk>
"""

import os
import sys

import requests

BASE = "https://developer.amazon.com/api/appstore"
TOKEN_URL = "https://api.amazon.com/auth/o2/token"


def fail(step: str, resp: requests.Response) -> None:
    sys.exit(f"Amazon: {step} non riuscito (HTTP {resp.status_code}): {resp.text[:500]}")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    apk = sys.argv[1]
    app_id = os.environ["AMAZON_APP_ID"]
    commit = os.environ.get("AMAZON_COMMIT", "0") == "1"

    r = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["AMAZON_CLIENT_ID"],
            "client_secret": os.environ["AMAZON_CLIENT_SECRET"],
            "scope": "appstore::apps:readwrite",
        },
        timeout=60,
    )
    if not r.ok:
        fail("autenticazione", r)
    auth = {"Authorization": f"Bearer {r.json()['access_token']}"}

    # Edit già aperto (bozza) oppure nuovo.
    r = requests.get(f"{BASE}/v1/applications/{app_id}/edits", headers=auth, timeout=60)
    if not r.ok:
        fail("lettura bozza", r)
    edit = r.json()
    if not edit or not edit.get("id"):
        r = requests.post(f"{BASE}/v1/applications/{app_id}/edits", headers=auth, timeout=60)
        if not r.ok:
            fail("creazione bozza", r)
        edit = r.json()
    edit_id = edit["id"]
    print(f"Bozza Amazon: {edit_id}")

    apks_url = f"{BASE}/v1/applications/{app_id}/edits/{edit_id}/apks"
    r = requests.get(apks_url, headers=auth, timeout=60)
    if not r.ok:
        fail("elenco APK", r)
    apks = r.json()
    with open(apk, "rb") as f:
        data = f.read()
    if apks:
        first = apks[0]
        r = requests.get(f"{apks_url}/{first['id']}", headers=auth, timeout=60)
        etag = r.headers.get("ETag", "")
        r = requests.put(
            f"{apks_url}/{first['id']}/replace",
            headers={**auth, "If-Match": etag, "Content-Type": "application/vnd.android.package-archive"},
            data=data,
            timeout=1800,
        )
        step = "sostituzione APK"
    else:
        r = requests.post(
            f"{apks_url}/upload",
            headers={**auth, "Content-Type": "application/vnd.android.package-archive"},
            data=data,
            timeout=1800,
        )
        step = "caricamento APK"
    if not r.ok:
        fail(step, r)
    print("APK caricato nella bozza.")

    if not commit:
        print("Commit non eseguito (AMAZON_COMMIT=0): la bozza resta in attesa.")
        return
    r = requests.get(f"{BASE}/v1/applications/{app_id}/edits/{edit_id}", headers=auth, timeout=60)
    etag = r.headers.get("ETag", "")
    r = requests.post(
        f"{BASE}/v1/applications/{app_id}/edits/{edit_id}/commit",
        headers={**auth, "If-Match": etag},
        timeout=60,
    )
    if not r.ok:
        fail("invio per la pubblicazione", r)
    print("Inviato ad Amazon per validazione e pubblicazione.")


if __name__ == "__main__":
    main()
