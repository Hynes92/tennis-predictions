"""
Feature-matrix construction shared by training (train.py) and scoring (score.py).

Keeping this in one module guarantees the model sees identically-built inputs in both
places: the same exclusions, the same encoding of categories, the same column order.
Only pandas is imported here, so scoring doesn't need scikit-learn.
"""

from __future__ import annotations

import pandas as pd

LABEL = "a_won"

# Columns that identify or describe a match but must never be model inputs
NON_FEATURES = {
    LABEL, "match_key", "tourney_id", "tourney_name", "tourney_level_raw", "source_dataset",
    "tourney_date", "event_date", "match_sequence_key", "round",
    "player_a_id", "player_b_id", "a_id_source", "b_id_source",
    "data_tier", "is_exhibition", "is_training_eligible",
    "tour", "competition_level", "surface",          # one-hot encoded instead
}

# Features that exist in history but CANNOT be known for an upcoming match from Betfair
# (no round, entry type or seeding). Training on them would create train/serve skew,
# so the model is trained only on what is available at prediction time.
NOT_AVAILABLE_AT_PREDICTION = {
    "round_order",
    "a_is_qualifier", "b_is_qualifier",
    "a_is_wildcard", "b_is_wildcard",
    "a_seed", "b_seed",
}
NON_FEATURES = NON_FEATURES | NOT_AVAILABLE_AT_PREDICTION

CATEGORICALS = ["tour", "competition_level", "surface"]


def _is_dummy(column: str) -> bool:
    return any(column.startswith(f"{c}_") for c in CATEGORICALS)


def build_matrix(df: pd.DataFrame, feature_columns: list[str] | None = None) -> pd.DataFrame:
    """
    Numeric feature matrix: every feature column as float (NaN = missing), plus one-hot
    columns for tour / competition level / surface.

    Training: call with feature_columns=None; every non-excluded column is used and a
    text column raises (it must be excluded or encoded).
    Scoring: pass the training feature list (features.json). Only those columns are built,
    in that order; a category value unseen in training gets all-zero dummies, and a
    numeric feature missing from the input is NaN.
    """
    if feature_columns is None:
        numeric_cols = [c for c in df.columns if c not in NON_FEATURES]
    else:
        numeric_cols = [c for c in feature_columns if not _is_dummy(c) and c in df.columns]

    feats = df[numeric_cols].copy()
    for c in feats.columns:
        col = feats[c]
        if col.dtype.name in ("bool", "boolean"):
            col = col.astype("Float64")
        if col.dtype == object or col.dtype.name in ("string", "str"):
            raise ValueError(f"Column {c!r} is text; add it to NON_FEATURES or encode it")
        feats[c] = pd.to_numeric(col, errors="coerce").astype("float64")

    cats = df[CATEGORICALS].astype("object").fillna("unknown").copy()
    # Betfair lists qualifying under the same competition as the main draw, so the two
    # can't be told apart when predicting: train on the same two levels the scorer will see.
    cats["competition_level"] = cats["competition_level"].replace({"qualifying": "main_tour"})
    dummies = pd.get_dummies(cats, prefix=CATEGORICALS, dtype="float64")

    X = pd.concat([feats, dummies], axis=1)
    if feature_columns is not None:
        X = X.reindex(columns=feature_columns)
        dummy_cols = [c for c in feature_columns if _is_dummy(c)]
        X[dummy_cols] = X[dummy_cols].fillna(0.0)
    return X