"""
Score upcoming matches with the trained model and append them to the predictions table.

Reads  : <dataset>.fct_upcoming_match_features      (built by dbt from current player state)
         <model-dir>/xgb_model.json, features.json, metrics.json, model_info.json
Writes : <dataset>.predictions                       (append-only; one row per match per run)

The feature matrix is built with features.build_matrix, the SAME function used in training,
aligned to the exact training column list in features.json.

Value flag: a side is flagged when the model's expected value at the current best back price
is at least VALUE_MIN_EV, and only for data tiers where the model has a backtested track
record (full / partial). market_prob_a is never a model input; it is only compared against.

Usage (from the repo root):
  python model/score.py --model-dir model/artifacts             # dev_gold
  python model/score.py --model-dir model/artifacts --dry-run   # score and print, write nothing
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

from features import build_matrix

DEFAULT_PROJECT = "tennis-predictor-509609"
DEFAULT_DATASET = "dev_gold"
DEFAULT_LOCATION = "EU"
SOURCE_TABLE = "fct_upcoming_match_features"
TARGET_TABLE = "predictions"

VALUE_MIN_EV = 0.05                       # flag only when expected value >= +5% per unit staked
VALUE_TIERS = {"full", "partial"}         # tiers with a backtested track record

log = logging.getLogger("score")


def load_upcoming(client, project: str, dataset: str) -> pd.DataFrame:
    return client.query(f"select * from `{project}.{dataset}.{SOURCE_TABLE}`").result().to_dataframe()


def load_model(model_dir: Path):
    from xgboost import XGBClassifier
    model = XGBClassifier()
    model.load_model(model_dir / "xgb_model.json")
    features = json.loads((model_dir / "features.json").read_text())
    metrics = json.loads((model_dir / "metrics.json").read_text())
    info_path = model_dir / "model_info.json"
    info = json.loads(info_path.read_text()) if info_path.exists() else {}
    return model, features, metrics, info


def expected_value(prob: pd.Series, price: pd.Series) -> pd.Series:
    """Profit per 1 unit staked at decimal odds `price` if the true win probability is `prob`."""
    return prob * price - 1


def score(df: pd.DataFrame, model, features: list[str], metrics: dict, info: dict,
          run_id: str, predicted_at: datetime) -> pd.DataFrame:
    X = build_matrix(df, feature_columns=features)
    p_a = model.predict_proba(X)[:, 1]

    tier_scores = metrics.get("test_by_data_tier", {})

    def tier_metric(tier: str, key: str):
        return tier_scores.get(tier, {}).get("xgboost", {}).get(key)

    out = pd.DataFrame({
        "run_id": run_id,
        "predicted_at": predicted_at,
        "model_trained_at": info.get("trained_at"),
        "model_git_sha": info.get("git_sha"),
        "market_id": df["market_id"],
        "market_start_time": df["market_start_time"],
        "snapshot_at": df["snapshot_at"],
        "competition_name": df["competition_name"],
        "tour": df["tour"],
        "competition_level": df["betfair_competition_level"],
        "tml_tourney_name": df["tml_tourney_name"],
        "surface": df["surface"],
        "player_a_name": df["player_a_name"],
        "player_b_name": df["player_b_name"],
        "a_selection_id": df["a_selection_id"],
        "b_selection_id": df["b_selection_id"],
        "player_a_id": df["player_a_id"],
        "player_b_id": df["player_b_id"],
        "a_form_variant": df["a_form_variant"],
        "b_form_variant": df["b_form_variant"],

        # model output
        "model_prob_a": p_a,
        "model_prob_b": 1 - p_a,
        "predicted_winner": np.where(p_a >= 0.5, df["player_a_name"], df["player_b_name"]),

        # baselines and market (comparison only)
        "elo_prob_a": df["elo_win_prob_a"],
        "market_prob_a": df["market_prob_a"],
        "a_back_price": df["a_back_price"],
        "b_back_price": df["b_back_price"],
        "total_matched": df["total_matched"],

        # confidence / data sufficiency
        "data_tier": df["data_tier"],
        "min_matches_last_52w": df["min_matches_last_52w"],
        "min_surface_matches_last_104w": df["min_surface_matches_last_104w"],
        "max_glicko_rd": df["max_glicko_rd"],
    })
    out["tier_backtest_accuracy"] = out["data_tier"].map(lambda t: tier_metric(t, "accuracy"))
    out["tier_backtest_log_loss"] = out["data_tier"].map(lambda t: tier_metric(t, "log_loss"))

    # edge vs market and value flag
    out["edge_a"] = out["model_prob_a"] - out["market_prob_a"].astype(float)
    out["ev_a"] = expected_value(out["model_prob_a"], out["a_back_price"].astype(float))
    out["ev_b"] = expected_value(out["model_prob_b"], out["b_back_price"].astype(float))
    best_is_a = out["ev_a"].fillna(-np.inf) >= out["ev_b"].fillna(-np.inf)
    out["value_side"] = np.where(best_is_a, "a", "b")
    out["value_ev"] = np.where(best_is_a, out["ev_a"], out["ev_b"])
    out["is_value_bet"] = (
        out["data_tier"].isin(VALUE_TIERS)
        & (out["value_ev"] >= VALUE_MIN_EV)
    ).fillna(False)
    out.loc[~out["is_value_bet"], ["value_side", "value_ev"]] = [None, np.nan]
    return out


def write(client, project: str, dataset: str, df: pd.DataFrame) -> None:
    from google.cloud import bigquery
    S = bigquery.SchemaField
    schema = [
        S("run_id", "STRING"), S("predicted_at", "TIMESTAMP"),
        S("model_trained_at", "STRING"), S("model_git_sha", "STRING"),
        S("market_id", "STRING"), S("market_start_time", "TIMESTAMP"), S("snapshot_at", "TIMESTAMP"),
        S("competition_name", "STRING"), S("tour", "STRING"), S("competition_level", "STRING"),
        S("tml_tourney_name", "STRING"), S("surface", "STRING"),
        S("player_a_name", "STRING"), S("player_b_name", "STRING"),
        S("a_selection_id", "INT64"), S("b_selection_id", "INT64"),
        S("player_a_id", "STRING"), S("player_b_id", "STRING"),
        S("a_form_variant", "STRING"), S("b_form_variant", "STRING"),
        S("model_prob_a", "FLOAT64"), S("model_prob_b", "FLOAT64"), S("predicted_winner", "STRING"),
        S("elo_prob_a", "FLOAT64"), S("market_prob_a", "FLOAT64"),
        S("a_back_price", "FLOAT64"), S("b_back_price", "FLOAT64"), S("total_matched", "FLOAT64"),
        S("data_tier", "STRING"), S("min_matches_last_52w", "INT64"),
        S("min_surface_matches_last_104w", "INT64"), S("max_glicko_rd", "FLOAT64"),
        S("tier_backtest_accuracy", "FLOAT64"), S("tier_backtest_log_loss", "FLOAT64"),
        S("edge_a", "FLOAT64"), S("ev_a", "FLOAT64"), S("ev_b", "FLOAT64"),
        S("value_side", "STRING"), S("value_ev", "FLOAT64"), S("is_value_bet", "BOOL"),
    ]
    df = df.copy()
    for c in ("min_matches_last_52w", "min_surface_matches_last_104w", "a_selection_id", "b_selection_id"):
        df[c] = pd.to_numeric(df[c], errors="coerce").astype("Int64")
    table = bigquery.Table(f"{project}.{dataset}.{TARGET_TABLE}", schema=schema)
    table.time_partitioning = bigquery.TimePartitioning(
        type_=bigquery.TimePartitioningType.DAY, field="predicted_at")
    table.clustering_fields = ["market_id"]
    client.create_table(table, exists_ok=True)
    job_config = bigquery.LoadJobConfig(
        schema=schema, write_disposition=bigquery.WriteDisposition.WRITE_APPEND)
    client.load_table_from_dataframe(df[[f.name for f in schema]], table,
                                     job_config=job_config).result()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Score upcoming matches into the predictions table.")
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--location", default=DEFAULT_LOCATION)
    p.add_argument("--model-dir", default=str(Path(__file__).resolve().parent / "artifacts"))
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)

    from google.cloud import bigquery
    client = bigquery.Client(project=args.project, location=args.location)

    model, features, metrics, info = load_model(Path(args.model_dir))
    log.info("Model trained %s (%d features)", info.get("trained_at", "unknown"), len(features))

    upcoming = load_upcoming(client, args.project, args.dataset)
    if upcoming.empty:
        log.info("No upcoming matches to score.")
        return 0

    run_id = uuid.uuid4().hex[:12]
    predictions = score(upcoming, model, features, metrics, info, run_id,
                        datetime.now(timezone.utc).replace(microsecond=0))

    by_tier = predictions.groupby("data_tier").size().to_dict()
    log.info("Scored %d matches %s; value bets flagged: %d",
             len(predictions), by_tier, int(predictions["is_value_bet"].sum()))
    cols = ["competition_name", "player_a_name", "player_b_name", "model_prob_a",
            "market_prob_a", "data_tier", "value_side", "value_ev"]
    with pd.option_context("display.width", 200, "display.max_columns", 20):
        print(predictions.sort_values("market_start_time")[cols].head(20).round(3).to_string(index=False))

    if args.dry_run:
        log.info("Dry run: nothing written.")
        return 0

    write(client, args.project, args.dataset, predictions)
    log.info("Appended %d rows to %s.%s.%s (run %s)",
             len(predictions), args.project, args.dataset, TARGET_TABLE, run_id)
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())