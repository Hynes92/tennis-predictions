"""
Snapshot upcoming tennis MATCH_ODDS markets from the Betfair Exchange into BigQuery bronze.

Each run is one snapshot. It writes:
  bronze.betfair_markets          one row per market per snapshot (catalogue + market-level book)
  bronze.betfair_price_snapshots  one row per runner (player) per snapshot (prices + volume)

Bronze rules followed here:
  * Everything Betfair returns is kept, including doubles and exhibitions. Filtering happens in dbt.
    The full API object is also stored as JSON in _raw_json.
  * Tables are append-only. Snapshots are identified by _snapshot_id / _snapshot_at, so the
    last snapshot before a match starts is the closest thing to a closing price.
  * Tables are partitioned by day on _snapshot_at and clustered on market_id, so queries
    stay cheap as snapshots accumulate.

Credentials come from environment variables BETFAIR_USERNAME, BETFAIR_PASSWORD, BETFAIR_APP_KEY
(the Delayed app key).

Usage (from the repo root, with the venv active):
  python ingestion/load_betfair.py --dry-run          # fetch and summarise, no BigQuery
  python ingestion/load_betfair.py                    # snapshot next 36 hours into bronze
  python ingestion/load_betfair.py --hours 48
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from collections import Counter
from datetime import datetime, timedelta, timezone

import requests

LOGIN_URL = "https://identitysso.betfair.com/api/login"
LOGOUT_URL = "https://identitysso.betfair.com/api/logout"
BETTING_URL = "https://api.betfair.com/exchange/betting/rest/v1.0"

TENNIS_EVENT_TYPE_ID = "2"
MARKET_TYPES = ["MATCH_ODDS"]
CATALOGUE_MAX_RESULTS = 1000      # Betfair's hard limit per listMarketCatalogue call
BOOK_BATCH_SIZE = 40              # EX_BEST_OFFERS has weight 5; the limit is 200 points per call
PRICE_DEPTH = 3                   # best 3 back and lay prices per runner

DEFAULT_PROJECT = "tennis-predictor-509609"
DEFAULT_DATASET = "bronze"
DEFAULT_LOCATION = "EU"
MARKETS_TABLE = "betfair_markets"
PRICES_TABLE = "betfair_price_snapshots"

HTTP_TIMEOUT = 30
log = logging.getLogger("load_betfair")


# --------------------------------------------------------------------------------------
# Betfair API client
# --------------------------------------------------------------------------------------

class BetfairClient:
    def __init__(self, username: str, password: str, app_key: str):
        self.username, self.password, self.app_key = username, password, app_key
        self.session = requests.Session()
        self.token: str | None = None

    def __enter__(self) -> "BetfairClient":
        self.login()
        return self

    def __exit__(self, *exc) -> None:
        self.logout()

    def login(self) -> None:
        resp = self.session.post(
            LOGIN_URL,
            data={"username": self.username, "password": self.password},
            headers={"X-Application": self.app_key, "Accept": "application/json"},
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        body = resp.json()
        if body.get("status") != "SUCCESS":
            raise RuntimeError(f"Betfair login failed: {body.get('error')}")
        self.token = body["token"]
        self.session.headers.update({
            "X-Application": self.app_key,
            "X-Authentication": self.token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        })
        log.info("Logged in to Betfair")

    def logout(self) -> None:
        if not self.token:
            return
        try:
            self.session.post(LOGOUT_URL, timeout=HTTP_TIMEOUT)
        except requests.RequestException:
            pass
        self.token = None

    def call(self, method: str, payload: dict, retries: int = 3):
        for attempt in range(1, retries + 1):
            try:
                resp = self.session.post(f"{BETTING_URL}/{method}/", json=payload, timeout=HTTP_TIMEOUT)
                if resp.status_code == 200:
                    return resp.json()
                # 4xx errors (bad key, bad request) won't fix themselves; fail straight away
                if 400 <= resp.status_code < 500:
                    raise RuntimeError(f"{method} failed ({resp.status_code}): {resp.text[:500]}")
                raise requests.HTTPError(f"{resp.status_code}: {resp.text[:200]}")
            except (requests.RequestException, requests.HTTPError) as exc:
                if attempt == retries:
                    raise
                wait = 2 ** attempt
                log.warning("%s failed (%s), retrying in %ss", method, exc, wait)
                time.sleep(wait)

    # -- endpoints --------------------------------------------------------------------

    def market_catalogue(self, start: datetime, end: datetime) -> list[dict]:
        """All tennis MATCH_ODDS markets starting in [start, end). Splits the window if a
        call hits Betfair's 1000-result limit."""
        result = self.call("listMarketCatalogue", {
            "filter": {
                "eventTypeIds": [TENNIS_EVENT_TYPE_ID],
                "marketTypeCodes": MARKET_TYPES,
                "inPlayOnly": False,
                "marketStartTime": {"from": iso_z(start), "to": iso_z(end)},
            },
            "marketProjection": ["EVENT", "COMPETITION", "MARKET_START_TIME", "RUNNER_DESCRIPTION"],
            "sort": "FIRST_TO_START",
            "maxResults": CATALOGUE_MAX_RESULTS,
        })
        if len(result) >= CATALOGUE_MAX_RESULTS and end - start > timedelta(minutes=30):
            mid = start + (end - start) / 2
            log.info("  window %s to %s hit the limit, splitting", iso_z(start), iso_z(end))
            merged = {m["marketId"]: m for m in self.market_catalogue(start, mid)}
            merged.update({m["marketId"]: m for m in self.market_catalogue(mid, end)})
            return list(merged.values())
        return result

    def market_books(self, market_ids: list[str]) -> list[dict]:
        books: list[dict] = []
        for i in range(0, len(market_ids), BOOK_BATCH_SIZE):
            batch = market_ids[i:i + BOOK_BATCH_SIZE]
            books += self.call("listMarketBook", {
                "marketIds": batch,
                "priceProjection": {
                    "priceData": ["EX_BEST_OFFERS"],
                    "exBestOffersOverrides": {"bestPricesDepth": PRICE_DEPTH},
                },
            })
        return books


# --------------------------------------------------------------------------------------
# Flatten API objects into bronze rows
# --------------------------------------------------------------------------------------

def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def market_rows(catalogue: list[dict], books: dict[str, dict], lineage: dict) -> list[dict]:
    rows = []
    for m in catalogue:
        ev, comp, book = m.get("event", {}), m.get("competition", {}), books.get(m["marketId"], {})
        rows.append({
            "market_id": m["marketId"],
            "market_name": m.get("marketName"),
            "market_start_time": m.get("marketStartTime"),
            "catalogue_total_matched": m.get("totalMatched"),
            "event_id": ev.get("id"),
            "event_name": ev.get("name"),
            "event_country_code": ev.get("countryCode"),
            "event_timezone": ev.get("timezone"),
            "event_open_date": ev.get("openDate"),
            "competition_id": comp.get("id"),
            "competition_name": comp.get("name"),
            "runner_count": len(m.get("runners", [])),
            "book_status": book.get("status"),
            "book_inplay": book.get("inplay"),
            "book_is_data_delayed": book.get("isMarketDataDelayed"),
            "book_total_matched": book.get("totalMatched"),
            "book_total_available": book.get("totalAvailable"),
            "book_last_match_time": book.get("lastMatchTime"),
            "book_version": book.get("version"),
            "_raw_json": json.dumps({"catalogue": m, "book": {k: v for k, v in book.items() if k != "runners"}}),
            **lineage,
        })
    return rows


def price_rows(catalogue: list[dict], books: dict[str, dict], lineage: dict) -> list[dict]:
    rows = []
    for m in catalogue:
        book = books.get(m["marketId"], {})
        book_runners = {r["selectionId"]: r for r in book.get("runners", [])}
        for r in m.get("runners", []):
            br = book_runners.get(r["selectionId"], {})
            ex = br.get("ex", {})
            row = {
                "market_id": m["marketId"],
                "selection_id": r["selectionId"],
                "runner_name": r.get("runnerName"),
                "sort_priority": r.get("sortPriority"),
                "handicap": r.get("handicap"),
                "runner_status": br.get("status"),
                "last_price_traded": br.get("lastPriceTraded"),
                "runner_total_matched": br.get("totalMatched"),
                "_raw_json": json.dumps(br) if br else None,
                **lineage,
            }
            for side, key in (("back", "availableToBack"), ("lay", "availableToLay")):
                levels = ex.get(key, [])
                for i in range(PRICE_DEPTH):
                    level = levels[i] if i < len(levels) else {}
                    row[f"{side}_price_{i + 1}"] = level.get("price")
                    row[f"{side}_size_{i + 1}"] = level.get("size")
            rows.append(row)
    return rows


# --------------------------------------------------------------------------------------
# BigQuery
# --------------------------------------------------------------------------------------

def lineage_fields(bq) -> list:
    return [
        bq.SchemaField("_snapshot_id", "STRING"),
        bq.SchemaField("_snapshot_at", "TIMESTAMP"),
        bq.SchemaField("_window_hours", "INT64"),
        bq.SchemaField("_raw_json", "STRING"),
    ]


def markets_schema(bq) -> list:
    S = bq.SchemaField
    return [
        S("market_id", "STRING"), S("market_name", "STRING"), S("market_start_time", "TIMESTAMP"),
        S("catalogue_total_matched", "FLOAT64"),
        S("event_id", "STRING"), S("event_name", "STRING"), S("event_country_code", "STRING"),
        S("event_timezone", "STRING"), S("event_open_date", "TIMESTAMP"),
        S("competition_id", "STRING"), S("competition_name", "STRING"), S("runner_count", "INT64"),
        S("book_status", "STRING"), S("book_inplay", "BOOL"), S("book_is_data_delayed", "BOOL"),
        S("book_total_matched", "FLOAT64"), S("book_total_available", "FLOAT64"),
        S("book_last_match_time", "TIMESTAMP"), S("book_version", "INT64"),
    ] + lineage_fields(bq)


def prices_schema(bq) -> list:
    S = bq.SchemaField
    fields = [
        S("market_id", "STRING"), S("selection_id", "INT64"), S("runner_name", "STRING"),
        S("sort_priority", "INT64"), S("handicap", "FLOAT64"), S("runner_status", "STRING"),
        S("last_price_traded", "FLOAT64"), S("runner_total_matched", "FLOAT64"),
    ]
    for side in ("back", "lay"):
        for i in range(1, PRICE_DEPTH + 1):
            fields += [S(f"{side}_price_{i}", "FLOAT64"), S(f"{side}_size_{i}", "FLOAT64")]
    return fields + lineage_fields(bq)


class BronzeWriter:
    def __init__(self, project: str, dataset: str, location: str):
        from google.cloud import bigquery
        self.bq = bigquery
        self.client = bigquery.Client(project=project, location=location)
        self.dataset_ref = f"{project}.{dataset}"
        ds = bigquery.Dataset(self.dataset_ref)
        ds.location = location
        self.client.create_dataset(ds, exists_ok=True)
        self._ensure_table(MARKETS_TABLE, markets_schema(bigquery))
        self._ensure_table(PRICES_TABLE, prices_schema(bigquery))

    def _ensure_table(self, name: str, schema: list) -> None:
        table = self.bq.Table(f"{self.dataset_ref}.{name}", schema=schema)
        table.time_partitioning = self.bq.TimePartitioning(
            type_=self.bq.TimePartitioningType.DAY, field="_snapshot_at")
        table.clustering_fields = ["market_id"]
        self.client.create_table(table, exists_ok=True)

    def load(self, name: str, schema: list, rows: list[dict]) -> None:
        if not rows:
            return
        job_config = self.bq.LoadJobConfig(
            schema=schema,
            source_format=self.bq.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition=self.bq.WriteDisposition.WRITE_APPEND,
        )
        self.client.load_table_from_json(rows, f"{self.dataset_ref}.{name}", job_config=job_config).result()


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Missing environment variable {name}.")
    return value


def run(args: argparse.Namespace) -> int:
    snapshot_at = datetime.now(timezone.utc).replace(microsecond=0)
    lineage = {
        "_snapshot_id": snapshot_at.strftime("%Y%m%dT%H%M%SZ"),
        "_snapshot_at": snapshot_at.isoformat(),
        "_window_hours": args.hours,
    }

    with BetfairClient(require_env("BETFAIR_USERNAME"), require_env("BETFAIR_PASSWORD"),
                       require_env("BETFAIR_APP_KEY")) as bf:
        catalogue = bf.market_catalogue(snapshot_at, snapshot_at + timedelta(hours=args.hours))
        log.info("Markets starting in next %dh: %d", args.hours, len(catalogue))
        books = {b["marketId"]: b for b in bf.market_books([m["marketId"] for m in catalogue])}
        log.info("Price books fetched: %d", len(books))

    markets = market_rows(catalogue, books, lineage)
    prices = price_rows(catalogue, books, lineage)

    missing_books = len(catalogue) - len(books)
    if missing_books:
        log.warning("%d markets had no price book (likely closed or suspended since listing)", missing_books)

    comps = Counter(m["competition_name"] or "(none)" for m in markets)
    for name, n in comps.most_common():
        log.info("  %4d  %s", n, name)

    if args.dry_run:
        log.info("Dry run: %d market rows, %d price rows (snapshot %s). Nothing written.",
                 len(markets), len(prices), lineage["_snapshot_id"])
        return 0

    writer = BronzeWriter(args.project, args.dataset, args.location)
    writer.load(MARKETS_TABLE, markets_schema(writer.bq), markets)
    writer.load(PRICES_TABLE, prices_schema(writer.bq), prices)
    log.info("Loaded snapshot %s: %d markets -> bronze.%s, %d runner rows -> bronze.%s",
             lineage["_snapshot_id"], len(markets), MARKETS_TABLE, len(prices), PRICES_TABLE)
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Snapshot Betfair tennis match odds into BigQuery bronze.")
    p.add_argument("--hours", type=int, default=36, help="look-ahead window for market start times")
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--location", default=DEFAULT_LOCATION)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


if __name__ == "__main__":
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        sys.exit(run(args))
    except Exception as exc:
        log.error("Snapshot FAILED: %s", exc)
        sys.exit(1)