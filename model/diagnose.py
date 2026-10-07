"""
Diagnose train/serve differences in the scoring path. Prints numbers only (no prices),
so it is safe for public run logs.

Checks:
  1. Parity    : score recent TRAINING rows through the scoring path (build_matrix with the
                 saved feature list + the saved model). Should reproduce the backtest:
                 mean prediction ~0.50, log loss ~0.62.
  2. Symmetry  : score upcoming matches as-is and with A and B swapped. A sound model gives
                 P(A) ~= 1 - P(A | swapped). A large gap means A/B columns are treated differently.
  3. Missingness: for every model feature, the share of NaN in training rows vs upcoming rows.
                 Features blank at scoring but rarely blank in training are prime suspects.
  4. Model     : number of trees in the loaded booster vs the best iteration recorded at training.

Usage: python model/diagnose.py --model-dir model/latest
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

from features import build_matrix

PROJECT, DATASET, LOCATION = "tennis-predictor-509609", "dev_gold", "EU"


def swap_sides(df: pd.DataFrame) -> pd.DataFrame:
    """Return the same matches with player A and player B exchanged."""
    out = df.copy()
    for col in df.columns:
        if col.startswith("a_") and f"b_{col[2:]}" in df.columns:
            out[col], out[f"b_{col[2:]}"] = df[f"b_{col[2:]}"], df[col]
    for col in df.columns:
        if col.startswith("diff_"):
            out[col] = -df[col]
    for col in ("elo_win_prob_a", "surface_elo_win_prob_a", "glicko_win_prob_a"):
        if col in df.columns:
            out[col] = 1 - df[col]
    return out


def log_loss(y, p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default="model/latest")
    args = ap.parse_args(argv)
    model_dir = Path(args.model_dir)

    from google.cloud import bigquery
    from xgboost import XGBClassifier

    model = XGBClassifier()
    model.load_model(model_dir / "xgb_model.json")
    features = json.loads((model_dir / "features.json").read_text())
    info = json.loads((model_dir / "model_info.json").read_text())

    client = bigquery.Client(project=PROJECT, location=LOCATION)
    train = client.query(
        f"select * from `{PROJECT}.{DATASET}.fct_match_features` "
        f"where is_training_eligible and tourney_date >= '2025-01-01'").result().to_dataframe()
    upcoming = client.query(
        f"select * from `{PROJECT}.{DATASET}.fct_upcoming_match_features` "
        f"where data_tier in ('full', 'partial')").result().to_dataframe()

    # 4. model
    booster = model.get_booster()
    n_trees = booster.num_boosted_rounds()
    print("\n== 4. Model ==")
    print(f"trees in loaded model: {n_trees}; best iteration at training: "
          f"{info.get('xgboost_best_iteration')}; sklearn best_iteration attr: "
          f"{getattr(model, 'best_iteration', None)}")
    print(f"booster feature names match features.json: {list(booster.feature_names or []) == features}")

    # 1. parity
    X_tr = build_matrix(train, feature_columns=features)
    p_tr = model.predict_proba(X_tr)[:, 1]
    y_tr = train["a_won"].astype(int).to_numpy()
    print("\n== 1. Parity (2025+ training rows through the scoring path) ==")
    print(f"rows {len(train)}  mean P(A) {p_tr.mean():.3f}  actual A win rate {y_tr.mean():.3f}  "
          f"log loss {log_loss(y_tr, p_tr):.4f}  (backtest XGBoost log loss {info.get('test_log_loss_xgboost')})")

    # 2. symmetry
    X_up = build_matrix(upcoming, feature_columns=features)
    X_sw = build_matrix(swap_sides(upcoming), feature_columns=features)
    p_up = model.predict_proba(X_up)[:, 1]
    p_sw = model.predict_proba(X_sw)[:, 1]
    X_tr_sw = build_matrix(swap_sides(train), feature_columns=features)
    p_tr_sw = model.predict_proba(X_tr_sw)[:, 1]
    print("\n== 2. Symmetry (P(A) vs 1 - P(A | swapped)) ==")
    print(f"training rows : mean P(A) {p_tr.mean():.3f}  mean 1-P(swapped) {(1 - p_tr_sw).mean():.3f}  "
          f"mean |gap| {np.abs(p_tr - (1 - p_tr_sw)).mean():.3f}")
    print(f"upcoming rows : mean P(A) {p_up.mean():.3f}  mean 1-P(swapped) {(1 - p_sw).mean():.3f}  "
          f"mean |gap| {np.abs(p_up - (1 - p_sw)).mean():.3f}  (n={len(upcoming)})")

    # 3. missingness
    nan_tr = X_tr.isna().mean()
    nan_up = X_up.isna().mean()
    diff = (nan_up - nan_tr).sort_values(ascending=False)
    print("\n== 3. Features most often blank at scoring vs training (share of rows NaN) ==")
    print(pd.DataFrame({"training": nan_tr[diff.index], "upcoming": nan_up[diff.index],
                        "difference": diff}).head(15).round(3).to_string())
    print("\n== Feature means: largest relative differences, upcoming vs training ==")
    means = pd.DataFrame({"training": X_tr.mean(), "upcoming": X_up.mean()})
    means["rel_diff"] = (means["upcoming"] - means["training"]).abs() / (means["training"].abs() + 1e-9)
    print(means.sort_values("rel_diff", ascending=False).head(15).round(3).to_string())
    return 0


if __name__ == "__main__":
    sys.exit(main())