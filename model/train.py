"""
Train and evaluate the match-outcome models against simple baselines.

Reads  : <dataset>.fct_match_features   (is_training_eligible rows only)
Writes : model/artifacts/
           metrics.json              all scores, overall and by segment
           calibration.png           predicted vs actual win rate on the test period
           feature_importance.png    top XGBoost features by gain
           xgb_model.json            the trained XGBoost model
           logreg.joblib             the trained logistic regression pipeline
           features.json             the exact feature list the models expect

Time-based split (never random: a random split would let the model learn from the future):
  train      : tourney_date <  2024-01-01
  validation : 2024                       (XGBoost early stopping)
  test       : tourney_date >= 2025-01-01 (touched once, for the final scores)

Models compared on the test period:
  elo        : the pre-match Elo win probability, as-is (the baseline to beat)
  logreg     : logistic regression on all features (interpretable benchmark)
  xgboost    : gradient-boosted trees on all features (the candidate model)

Usage (from the repo root, venv active):
  python model/train.py
  python model/train.py --dataset gold      # prod data
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, brier_score_loss, log_loss, roc_auc_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

DEFAULT_PROJECT = "tennis-predictor-509609"
DEFAULT_DATASET = "dev_gold"
DEFAULT_LOCATION = "EU"
TABLE = "fct_match_features"

TRAIN_END = "2024-01-01"
TEST_START = "2025-01-01"

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"

from features import CATEGORICALS, LABEL, NON_FEATURES, build_matrix  # shared with score.py

# Chart styling (reference data-viz palette, light mode)
SURFACE, TEXT, TEXT_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
SERIES = {"elo": "#2a78d6", "logreg": "#eb6834", "xgboost": "#1baf7a"}
LABELS = {"elo": "Elo only", "logreg": "Logistic regression", "xgboost": "XGBoost"}

log = logging.getLogger("train")


# --------------------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------------------

def load(project: str, dataset: str, location: str) -> pd.DataFrame:
    from google.cloud import bigquery
    client = bigquery.Client(project=project, location=location)
    sql = f"select * from `{project}.{dataset}.{TABLE}` where is_training_eligible"
    df = client.query(sql).result().to_dataframe()
    df["tourney_date"] = pd.to_datetime(df["tourney_date"])
    return df


def split(df: pd.DataFrame, X: pd.DataFrame):
    train = df["tourney_date"] < TRAIN_END
    valid = (df["tourney_date"] >= TRAIN_END) & (df["tourney_date"] < TEST_START)
    test = df["tourney_date"] >= TEST_START
    return train.to_numpy(), valid.to_numpy(), test.to_numpy()


# --------------------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------------------

def train_logreg(X: pd.DataFrame, y: np.ndarray):
    model = make_pipeline(
        SimpleImputer(strategy="median", add_indicator=True),   # missing-ness itself is informative
        StandardScaler(),
        LogisticRegression(C=1.0, max_iter=3000),
    )
    model.fit(X, y)
    return model


def train_xgboost(X_tr, y_tr, X_va, y_va):
    from xgboost import XGBClassifier
    model = XGBClassifier(
        n_estimators=3000,
        learning_rate=0.03,
        max_depth=5,
        min_child_weight=20,
        subsample=0.8,
        colsample_bytree=0.8,
        reg_lambda=1.0,
        objective="binary:logistic",
        eval_metric="logloss",
        early_stopping_rounds=100,     # stop when validation (2024) log loss stops improving
        tree_method="hist",
        n_jobs=-1,
        random_state=42,
    )
    model.fit(X_tr, y_tr, eval_set=[(X_va, y_va)], verbose=False)
    return model


# --------------------------------------------------------------------------------------
# Evaluation
# --------------------------------------------------------------------------------------

def scores(y: np.ndarray, p: np.ndarray) -> dict:
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return {
        "n": int(len(y)),
        "log_loss": round(float(log_loss(y, p, labels=[0, 1])), 5),
        "brier": round(float(brier_score_loss(y, p)), 5),
        "accuracy": round(float(accuracy_score(y, p > 0.5)), 4),
        "auc": round(float(roc_auc_score(y, p)), 4) if len(np.unique(y)) > 1 else None,
    }


def segment_scores(test_df: pd.DataFrame, preds: dict[str, np.ndarray], column: str) -> dict:
    out = {}
    y = test_df[LABEL].to_numpy()
    for value in sorted(test_df[column].dropna().unique()):
        mask = (test_df[column] == value).to_numpy()
        if mask.sum() < 200:
            continue
        out[str(value)] = {name: scores(y[mask], p[mask]) for name, p in preds.items()}
    return out


def calibration_table(y: np.ndarray, p: np.ndarray, bins: int = 10) -> pd.DataFrame:
    edges = np.linspace(0, 1, bins + 1)
    idx = np.clip(np.digitize(p, edges) - 1, 0, bins - 1)
    t = pd.DataFrame({"bin": idx, "p": p, "y": y}).groupby("bin").agg(
        predicted=("p", "mean"), actual=("y", "mean"), n=("y", "size"))
    return t[t["n"] >= 50]


# --------------------------------------------------------------------------------------
# Charts
# --------------------------------------------------------------------------------------

def _style(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=TEXT_2, labelsize=9)
    ax.grid(color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def plot_calibration(y: np.ndarray, preds: dict[str, np.ndarray], path: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(6.4, 6.0), facecolor=SURFACE)
    _style(ax)
    ax.plot([0, 1], [0, 1], color=TEXT_2, linewidth=1, linestyle=(0, (4, 4)), label="Perfect calibration")
    for name, p in preds.items():
        t = calibration_table(y, p)
        ax.plot(t["predicted"], t["actual"], color=SERIES[name], linewidth=2,
                marker="o", markersize=5, markeredgecolor=SURFACE, markeredgewidth=1.5,
                label=f"{LABELS[name]} (log loss {scores(y, p)['log_loss']:.4f})")
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_xlabel("Predicted probability player A wins", color=TEXT_2, fontsize=10)
    ax.set_ylabel("Actual share of matches player A won", color=TEXT_2, fontsize=10)
    ax.set_title(f"Calibration on the test period ({TEST_START[:4]} onwards)",
                 color=TEXT, fontsize=12, loc="left", pad=12)
    leg = ax.legend(frameon=False, fontsize=9, loc="upper left")
    for text in leg.get_texts():
        text.set_color(TEXT)
    fig.tight_layout()
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    plt.close(fig)


def plot_importance(importance: pd.Series, path: Path, top: int = 20) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    imp = importance.sort_values(ascending=True).tail(top)
    imp = imp / imp.sum()
    fig, ax = plt.subplots(figsize=(7.5, 0.32 * len(imp) + 1.2), facecolor=SURFACE)
    _style(ax)
    ax.grid(axis="y", visible=False)
    ax.barh(imp.index, imp.values, color=SERIES["elo"], height=0.7)
    ax.set_xlabel("Share of total gain among the top features", color=TEXT_2, fontsize=10)
    ax.set_title(f"XGBoost: top {len(imp)} features by gain", color=TEXT, fontsize=12, loc="left", pad=12)
    fig.tight_layout()
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    plt.close(fig)


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

def run(df: pd.DataFrame, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    X = build_matrix(df)
    y = df[LABEL].astype(int).to_numpy()
    tr, va, te = split(df, X)
    log.info("Rows: train %d | validation %d | test %d | features %d",
             tr.sum(), va.sum(), te.sum(), X.shape[1])

    t0 = time.time()
    logreg = train_logreg(X[tr], y[tr])
    log.info("Logistic regression trained in %.0fs", time.time() - t0)

    t0 = time.time()
    xgb = train_xgboost(X[tr], y[tr], X[va], y[va])
    log.info("XGBoost trained in %.0fs (best iteration %s)", time.time() - t0, xgb.best_iteration)

    X_te, y_te, test_df = X[te], y[te], df[te]
    preds = {
        "elo": test_df["elo_win_prob_a"].astype(float).fillna(0.5).to_numpy(),
        "logreg": logreg.predict_proba(X_te)[:, 1],
        "xgboost": xgb.predict_proba(X_te)[:, 1],
    }

    metrics = {
        "split": {"train_end": TRAIN_END, "test_start": TEST_START,
                  "n_train": int(tr.sum()), "n_valid": int(va.sum()), "n_test": int(te.sum())},
        "xgboost_best_iteration": int(xgb.best_iteration),
        "test_overall": {name: scores(y_te, p) for name, p in preds.items()},
        "test_by_data_tier": segment_scores(test_df, preds, "data_tier"),
        "test_by_tour": segment_scores(test_df, preds, "tour"),
        "test_by_competition_level": segment_scores(test_df, preds, "competition_level"),
        "test_by_surface": segment_scores(test_df, preds, "surface"),
    }

    importance = pd.Series(xgb.get_booster().get_score(importance_type="gain"))
    metrics["xgboost_top_features"] = {k: round(float(v), 2)
                                       for k, v in importance.sort_values(ascending=False).head(25).items()}

    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))
    (out_dir / "features.json").write_text(json.dumps(list(X.columns), indent=2))
    import os
    from datetime import datetime, timezone
    (out_dir / "model_info.json").write_text(json.dumps({
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "git_sha": os.environ.get("GITHUB_SHA"),
        "train_end": TRAIN_END,
        "test_start": TEST_START,
        "n_features": int(X.shape[1]),
        "xgboost_best_iteration": int(xgb.best_iteration),
        "test_log_loss_xgboost": metrics["test_overall"]["xgboost"]["log_loss"],
    }, indent=2))
    xgb.save_model(out_dir / "xgb_model.json")
    # Reference sample: raw test rows + the trained model's predictions. score.py rebuilds and
    # re-scores these every run and refuses to write predictions if anything differs, which
    # checks the whole scoring path (feature building + model loading) against training.
    reference = test_df.head(1000).copy()
    reference["_reference_prediction"] = preds["xgboost"][:1000]
    reference.to_parquet(out_dir / "reference.parquet", index=False)
    import joblib
    joblib.dump(logreg, out_dir / "logreg.joblib")
    plot_calibration(y_te, preds, out_dir / "calibration.png")
    plot_importance(importance, out_dir / "feature_importance.png")

    # Out-of-sample predictions for the validation (2024) and test (2025+) periods, for the
    # market benchmark in dbt. Validation was used for early stopping only, so it's still
    # unseen by the fitted trees; betting rules are chosen on it and checked on test.
    oos = va | te
    backtest = pd.DataFrame({
        "match_key": df.loc[oos, "match_key"].to_numpy(),
        "split": np.where(te[oos], "test", "valid"),
        "tourney_date": pd.to_datetime(df.loc[oos, "tourney_date"]).dt.date.to_numpy(),
        "a_won": y[oos].astype(bool),
        "data_tier": df.loc[oos, "data_tier"].to_numpy(),
        "model_prob_a": xgb.predict_proba(X[oos])[:, 1],
        "logreg_prob_a": logreg.predict_proba(X[oos])[:, 1],
        "elo_prob_a": df.loc[oos, "elo_win_prob_a"].astype(float).to_numpy(),
    })
    backtest.to_parquet(out_dir / "backtest_predictions.parquet", index=False)
    return metrics, backtest


def print_summary(metrics: dict) -> None:
    print("\nTest period scores (lower log loss / Brier is better)")
    print(f"  {'model':22} {'log loss':>9} {'brier':>8} {'accuracy':>9} {'auc':>7}")
    for name, s in metrics["test_overall"].items():
        print(f"  {LABELS[name]:22} {s['log_loss']:9.4f} {s['brier']:8.4f} {s['accuracy']:9.3f} {s['auc']:7.3f}")
    print("\nLog loss by data tier")
    for tier, by_model in metrics["test_by_data_tier"].items():
        cells = "  ".join(f"{LABELS[m]}: {s['log_loss']:.4f}" for m, s in by_model.items())
        print(f"  {tier:8} (n={by_model['elo']['n']:>6})  {cells}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Train and evaluate match-outcome models.")
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--dataset", default=DEFAULT_DATASET)
    p.add_argument("--location", default=DEFAULT_LOCATION)
    p.add_argument("--no-upload", action="store_true",
                   help="don't write backtest predictions to BigQuery")
    args = p.parse_args(argv)

    t0 = time.time()
    df = load(args.project, args.dataset, args.location)
    log.info("Loaded %d training-eligible matches in %.0fs", len(df), time.time() - t0)

    metrics, backtest = run(df, ARTIFACTS)
    print_summary(metrics)
    log.info("Artifacts written to %s", ARTIFACTS)
    if not args.no_upload:
        upload_backtest(backtest, args.project, args.dataset, args.location)
    return 0


def upload_backtest(backtest: pd.DataFrame, project: str, dataset: str, location: str) -> None:
    """Replace <dataset>.backtest_predictions with this model's out-of-sample predictions."""
    import os
    from datetime import datetime, timezone
    from google.cloud import bigquery
    S = bigquery.SchemaField
    schema = [
        S("match_key", "STRING"), S("split", "STRING"), S("tourney_date", "DATE"),
        S("a_won", "BOOL"), S("data_tier", "STRING"),
        S("model_prob_a", "FLOAT64"), S("logreg_prob_a", "FLOAT64"), S("elo_prob_a", "FLOAT64"),
        S("model_trained_at", "TIMESTAMP"), S("model_git_sha", "STRING"),
    ]
    out = backtest.copy()
    out["model_trained_at"] = datetime.now(timezone.utc)
    out["model_git_sha"] = os.environ.get("GITHUB_SHA")
    client = bigquery.Client(project=project, location=location)
    table = f"{project}.{dataset}.backtest_predictions"
    client.load_table_from_dataframe(
        out[[f.name for f in schema]], table,
        job_config=bigquery.LoadJobConfig(
            schema=schema, write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE),
    ).result()
    log.info("Wrote %d out-of-sample predictions to %s", len(out), table)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())