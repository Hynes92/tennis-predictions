"""
Read-only Betfair connection test: log in, list upcoming tennis match-odds markets,
fetch prices for a sample, log out. Nothing is written anywhere.

Needs environment variables BETFAIR_USERNAME, BETFAIR_PASSWORD, BETFAIR_APP_KEY.

  python ingestion/test_betfair.py            # next 36 hours
  python ingestion/test_betfair.py --hours 12
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

import requests

LOGIN_URL = "https://identitysso.betfair.com/api/login"
LOGOUT_URL = "https://identitysso.betfair.com/api/logout"
BETTING_URL = "https://api.betfair.com/exchange/betting/rest/v1.0"
TENNIS_EVENT_TYPE_ID = "2"
TIMEOUT = 30


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Missing environment variable {name}. Set it with setx, then open a NEW PowerShell window.")
    return value


def login(session: requests.Session, username: str, password: str, app_key: str) -> str:
    resp = session.post(
        LOGIN_URL,
        data={"username": username, "password": password},
        headers={"X-Application": app_key, "Accept": "application/json"},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    body = resp.json()
    if body.get("status") != "SUCCESS":
        sys.exit(f"Login failed: {body.get('error')}\n"
                 "  INVALID_USERNAME_OR_PASSWORD -> check BETFAIR_USERNAME / BETFAIR_PASSWORD\n"
                 "  ACCOUNT_PENDING_PASSWORD_CHANGE / KYC_SUSPEND / ... -> log in on betfair.com and clear any prompts\n"
                 "  SECURITY_QUESTION_WRONG_3X or 2FA related -> log in on the website first")
    return body["token"]


def api(session: requests.Session, method: str, payload: dict) -> list | dict:
    resp = session.post(f"{BETTING_URL}/{method}/", json=payload, timeout=TIMEOUT)
    if resp.status_code != 200:
        sys.exit(f"{method} failed ({resp.status_code}): {resp.text[:500]}")
    return resp.json()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--hours", type=int, default=36)
    args = p.parse_args()

    username, password, app_key = env("BETFAIR_USERNAME"), env("BETFAIR_PASSWORD"), env("BETFAIR_APP_KEY")

    s = requests.Session()
    token = login(s, username, password, app_key)
    print("Login OK")
    s.headers.update({
        "X-Application": app_key,
        "X-Authentication": token,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })

    try:
        now = datetime.now(timezone.utc)
        to = now + timedelta(hours=args.hours)
        catalogue = api(s, "listMarketCatalogue", {
            "filter": {
                "eventTypeIds": [TENNIS_EVENT_TYPE_ID],
                "marketTypeCodes": ["MATCH_ODDS"],
                "inPlayOnly": False,
                "marketStartTime": {
                    "from": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "to": to.strftime("%Y-%m-%dT%H:%M:%SZ"),
                },
            },
            "marketProjection": ["EVENT", "COMPETITION", "MARKET_START_TIME", "RUNNER_DESCRIPTION"],
            "sort": "FIRST_TO_START",
            "maxResults": 1000,
        })

        singles = [m for m in catalogue if "/" not in m["event"]["name"]]   # doubles use "A/B v C/D"
        print(f"\nUpcoming tennis MATCH_ODDS markets in next {args.hours}h: {len(catalogue)} "
              f"({len(singles)} singles, {len(catalogue) - len(singles)} doubles)")
        if len(catalogue) == 1000:
            print("  (hit the 1000 limit; the real loader will page through time windows)")

        comps = Counter(m.get("competition", {}).get("name", "(no competition)") for m in singles)
        print("\nSingles markets by competition:")
        for name, n in comps.most_common():
            print(f"  {n:4d}  {name}")

        # Prices for the first 40 singles markets (EX_BEST_OFFERS has a weight limit of 40 markets/request)
        sample = singles[:40]
        if not sample:
            print("\nNo singles markets found in this window.")
            return
        books = api(s, "listMarketBook", {
            "marketIds": [m["marketId"] for m in sample],
            "priceProjection": {"priceData": ["EX_BEST_OFFERS"]},
        })
        book_by_id = {b["marketId"]: b for b in books}

        print(f"\nFirst {min(15, len(sample))} matches with best back prices (delayed):")
        print(f"  {'start (UTC)':16}  {'competition':28}  {'match':45}  back prices    matched")
        for m in sample[:15]:
            book = book_by_id.get(m["marketId"], {})
            price_by_sel = {}
            for r in book.get("runners", []):
                backs = r.get("ex", {}).get("availableToBack", [])
                price_by_sel[r["selectionId"]] = backs[0]["price"] if backs else None
            prices = " / ".join(
                f"{price_by_sel.get(r['selectionId']) or '-'}" for r in m["runners"]
            )
            start = m["marketStartTime"][:16].replace("T", " ")
            comp = m.get("competition", {}).get("name", "")[:28]
            print(f"  {start:16}  {comp:28}  {m['event']['name'][:45]:45}  {prices:13}  "
                  f"£{book.get('totalMatched', 0):,.0f}")
        print("\nIf you see matches and prices above, the credentials and delayed key work.")
    finally:
        s.post(LOGOUT_URL, headers={"X-Application": app_key, "X-Authentication": token,
                                    "Accept": "application/json"}, timeout=TIMEOUT)


if __name__ == "__main__":
    main()