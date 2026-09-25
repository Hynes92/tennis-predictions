"""
Load TennisMyLife (TML) match data into the BigQuery bronze layer.

Bronze rules followed here:
  * Data is stored exactly as downloaded. Every CSV column is loaded as STRING,
    and all casting happens in dbt staging. (TML player IDs mix letters and
    numbers, e.g. "B0CD", so BigQuery's type autodetection would break them.)
  * Tables are append-only. Each load adds lineage columns (_source_file,
    _source_url, _source_md5, _loaded_at). dbt staging keeps the newest copy of
    each match.
  * Files whose content hasn't changed since the last load are skipped,
    tracked in bronze._ingestion_log, so reruns are cheap and idempotent.

Usage (from the repo root, with the venv active):
  python ingestion/load_tml.py --mode backfill          # one-off: every year
  python ingestion/load_tml.py --mode daily             # nightly: current season + ongoing
  python ingestion/load_tml.py --mode daily --dry-run   # download and parse only, no BigQuery
  python ingestion/load_tml.py --mode backfill --datasets atp players
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import logging
import sys
import time
from dataclasses import dataclass
from datetime import date, datetime, timezone

import requests

BASE_URL = "https://stats.tennismylife.org/data"
DEFAULT_PROJECT = "tennis-predictor-509609"
DEFAULT_DATASET = "bronze"
DEFAULT_LOCATION = "EU"
LOG_TABLE = "_ingestion_log"

REQUEST_PAUSE_SECONDS = 1.0     # be polite to a free, community-run site
HTTP_TIMEOUT_SECONDS = 60
USER_AGENT = "tennis-predictions-portfolio/0.1 (personal non-commercial project)"

log = logging.getLogger("load_tml")


# --------------------------------------------------------------------------------------
# File catalogue
# --------------------------------------------------------------------------------------

@dataclass(frozen=True)
class SourceDataset:
    key: str                    # CLI name
    table: str                  # bronze table name
    yearly_path: str | None     # path template with {year}, relative to BASE_URL
    first_year: int | None      # earliest year to try; missing years are skipped
    ongoing_path: str | None    # in-progress tournaments file, if the source has one
    write_mode: str             # "append" (match data) or "truncate" (reference data)


DATASETS: dict[str, SourceDataset] = {
    "atp": SourceDataset(
        key="atp", table="tml_atp_matches",
        yearly_path="{year}.csv", first_year=1968,
        ongoing_path="ongoing_tourneys.csv", write_mode="append",
    ),
    "challenger": SourceDataset(
        key="challenger", table="tml_challenger_matches",
        yearly_path="{year}_challenger.csv", first_year=1978,
        ongoing_path="challenger_ongoing_tourneys.csv", write_mode="append",
    ),
    "atp_quali": SourceDataset(
        key="atp_quali", table="tml_atp_quali_matches",
        yearly_path="atp_quali/{year}_atp_quali.csv", first_year=1968,
        ongoing_path=None, write_mode="append",
    ),
    "wta": SourceDataset(
        key="wta", table="tml_wta_matches",
        yearly_path="{year}_wta.csv", first_year=1990,
        ongoing_path="wta_ongoing_tourneys.csv", write_mode="append",
    ),
    "players": SourceDataset(
        key="players", table="tml_atp_players",
        yearly_path=None, first_year=None,
        ongoing_path="ATP_Database.csv", write_mode="truncate",
    ),
}


def files_to_fetch(ds: SourceDataset, mode: str, today: date) -> list[str]:
    """Return the relative file paths to download for one dataset."""
    paths: list[str] = []
    if ds.yearly_path:
        if mode == "backfill":
            years = range(ds.first_year, today.year + 1)
        else:
            # Daily: the current season. In January, also re-check last season,
            # since late results and corrections to it can still arrive.
            years = [today.year - 1, today.year] if today.month == 1 else [today.year]
        paths += [ds.yearly_path.format(year=y) for y in years]
    if ds.ongoing_path:
        paths.append(ds.ongoing_path)
    return paths


# --------------------------------------------------------------------------------------
# Download + parse
# --------------------------------------------------------------------------------------

def download(session: requests.Session, path: str, retries: int = 3) -> bytes | None:
    """Download one file. Returns None if it doesn't exist (404)."""
    url = f"{BASE_URL}/{path}"
    for attempt in range(1, retries + 1):
        try:
            resp = session.get(url, timeout=HTTP_TIMEOUT_SECONDS)
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return resp.content
        except requests.RequestException as exc:
            if attempt == retries:
                raise
            wait = 2 ** attempt
            log.warning("  %s failed (%s), retrying in %ss", path, exc, wait)
            time.sleep(wait)
    return None


def parse_csv(content: bytes) -> tuple[list[str], list[dict[str, str | None]]]:
    """Parse CSV bytes into (column names, rows). Empty strings become None."""
    text = content.decode("utf-8-sig")          # strips a BOM if present
    reader = csv.DictReader(io.StringIO(text))
    columns = [c.strip() for c in (reader.fieldnames or [])]
    rows = []
    for raw in reader:
        rows.append({
            col.strip(): (val.strip() if val is not None and val.strip() != "" else None)
            for col, val in raw.items()
            if col is not None                   # drops overflow from ragged lines
        })
    return columns, rows


def add_lineage(rows: list[dict], path: str, md5: str, loaded_at: str) -> list[dict]:
    url = f"{BASE_URL}/{path}"
    for i, row in enumerate(rows, start=1):
        row["_source_file"] = path
        row["_source_url"] = url
        row["_source_row_number"] = i
        row["_source_md5"] = md5
        row["_loaded_at"] = loaded_at
    return rows


# --------------------------------------------------------------------------------------
# BigQuery
# --------------------------------------------------------------------------------------

class BronzeWriter:
    def __init__(self, project: str, dataset: str, location: str):
        from google.cloud import bigquery   # imported here so --dry-run needs no GCP libs
        self.bq = bigquery
        self.client = bigquery.Client(project=project, location=location)
        self.dataset_ref = f"{project}.{dataset}"
        self.location = location
        self._ensure_dataset()
        self._ensure_log_table()

    def _ensure_dataset(self) -> None:
        ds = self.bq.Dataset(self.dataset_ref)
        ds.location = self.location
        self.client.create_dataset(ds, exists_ok=True)

    def _log_schema(self) -> list:
        return [
            self.bq.SchemaField("source_file", "STRING"),
            self.bq.SchemaField("target_table", "STRING"),
            self.bq.SchemaField("file_md5", "STRING"),
            self.bq.SchemaField("row_count", "INT64"),
            self.bq.SchemaField("loaded_at", "TIMESTAMP"),
        ]

    def _ensure_log_table(self) -> None:
        table = self.bq.Table(f"{self.dataset_ref}.{LOG_TABLE}", schema=self._log_schema())
        self.client.create_table(table, exists_ok=True)

    def latest_md5s(self) -> dict[str, str]:
        """Most recent md5 loaded for each source file."""
        sql = f"""
            select source_file, file_md5
            from `{self.dataset_ref}.{LOG_TABLE}`
            qualify row_number() over (partition by source_file order by loaded_at desc) = 1
        """
        return {r.source_file: r.file_md5 for r in self.client.query(sql).result()}

    def _existing_schema(self, table: str) -> list:
        from google.api_core.exceptions import NotFound
        try:
            return list(self.client.get_table(f"{self.dataset_ref}.{table}").schema)
        except NotFound:
            return []

    def load(self, table: str, columns: list[str], rows: list[dict], write_mode: str) -> None:
        bq = self.bq
        lineage = [
            bq.SchemaField("_source_file", "STRING"),
            bq.SchemaField("_source_url", "STRING"),
            bq.SchemaField("_source_row_number", "INT64"),
            bq.SchemaField("_source_md5", "STRING"),
            bq.SchemaField("_loaded_at", "TIMESTAMP"),
        ]
        if write_mode == "append":
            # Keep the existing table's column order, and add any columns this file
            # introduces at the end. Columns missing from this file simply load as NULL.
            schema = self._existing_schema(table) or lineage
            known = {f.name.lower() for f in schema}
            schema = schema + [bq.SchemaField(c, "STRING") for c in columns if c.lower() not in known]
        else:
            schema = [bq.SchemaField(c, "STRING") for c in columns] + lineage
        job_config = bq.LoadJobConfig(
            schema=schema,
            source_format=bq.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition=(
                bq.WriteDisposition.WRITE_TRUNCATE if write_mode == "truncate"
                else bq.WriteDisposition.WRITE_APPEND
            ),
        )
        if write_mode == "append":
            # Older files can have fewer columns than newer ones; let the table grow.
            job_config.schema_update_options = [bq.SchemaUpdateOption.ALLOW_FIELD_ADDITION]
        job = self.client.load_table_from_json(rows, f"{self.dataset_ref}.{table}", job_config=job_config)
        job.result()   # raises on failure

    def record(self, path: str, table: str, md5: str, row_count: int, loaded_at: str) -> None:
        # A load job rather than a streaming insert: load jobs are free and work
        # without billing, and the row is queryable immediately.
        job_config = self.bq.LoadJobConfig(
            schema=self._log_schema(),
            source_format=self.bq.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition=self.bq.WriteDisposition.WRITE_APPEND,
        )
        self.client.load_table_from_json(
            [{"source_file": path, "target_table": table, "file_md5": md5,
              "row_count": row_count, "loaded_at": loaded_at}],
            f"{self.dataset_ref}.{LOG_TABLE}",
            job_config=job_config,
        ).result()


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

def run(args: argparse.Namespace) -> int:
    today = date.today()
    selected = [DATASETS[k] for k in args.datasets]

    writer = None if args.dry_run else BronzeWriter(args.project, args.dataset, args.location)
    seen_md5 = {} if (writer is None or args.force) else writer.latest_md5s()

    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT

    summary = {"loaded": 0, "unchanged": 0, "missing": 0, "rows": 0}
    failures: list[str] = []

    for ds in selected:
        paths = files_to_fetch(ds, args.mode, today)
        log.info("%s -> bronze.%s (%d files)", ds.key, ds.table, len(paths))

        for path in paths:
            try:
                content = download(session, path)
                time.sleep(REQUEST_PAUSE_SECONDS)
                if content is None:
                    summary["missing"] += 1
                    log.debug("  %s not published, skipping", path)
                    continue

                md5 = hashlib.md5(content).hexdigest()
                if seen_md5.get(path) == md5:
                    summary["unchanged"] += 1
                    log.info("  %s unchanged, skipping", path)
                    continue

                columns, rows = parse_csv(content)
                if not rows:
                    log.info("  %s is empty, skipping", path)
                    continue

                loaded_at = datetime.now(timezone.utc).isoformat()
                rows = add_lineage(rows, path, md5, loaded_at)

                if writer:
                    writer.load(ds.table, columns, rows, ds.write_mode)
                    writer.record(path, ds.table, md5, len(rows), loaded_at)

                summary["loaded"] += 1
                summary["rows"] += len(rows)
                log.info("  %s: %d rows%s", path, len(rows), " (dry run)" if args.dry_run else "")

            except Exception as exc:  # keep going; report at the end
                failures.append(path)
                log.error("  %s FAILED: %s", path, exc)

    log.info(
        "Done. files loaded=%d unchanged=%d not_published=%d rows=%d failed=%d",
        summary["loaded"], summary["unchanged"], summary["missing"], summary["rows"], len(failures),
    )
    if failures:
        log.error("Failed files: %s", ", ".join(failures))
        return 1
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Load TennisMyLife CSVs into BigQuery bronze.")
    p.add_argument("--mode", choices=["backfill", "daily"], default="daily")
    p.add_argument("--datasets", nargs="+", choices=list(DATASETS), default=list(DATASETS))
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--location", default=DEFAULT_LOCATION)
    p.add_argument("--dry-run", action="store_true", help="download and parse only; no BigQuery")
    p.add_argument("--force", action="store_true", help="reload files even if unchanged")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


if __name__ == "__main__":
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    sys.exit(run(args))