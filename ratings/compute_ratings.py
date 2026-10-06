"""
Compute Elo and Glicko-2 ratings for every player before every completed match.

Why Python and not dbt SQL: ratings are sequential (each match's rating depends on the
result of the previous one), which window functions can't express. This step sits between
two dbt runs:

    dbt build (staging -> int_tml__player_matches)  ->  this script  ->  dbt build (features)

Input : <source_dataset>.int_tml__player_matches   (completed matches only)
Output: <target_dataset>.player_match_ratings      (one row per player per match, PRE-match ratings)

Point-in-time rule: every rating written for a match is the rating the player had GOING INTO
that match. The match's own result only affects ratings for later matches, so using these
columns as model features never leaks the outcome.

Ratings:
  * Elo, overall and per surface. Start 1500, K = 250 / (matches_played + 5) ** 0.4
    (the decaying K-factor popularised by FiveThirtyEight's tennis Elo).
  * Glicko-2 (Glickman 2012), one match per update, with rating deviation (RD) inflated for
    each week a player has been inactive. RD is the per-player uncertainty measure used for
    the data_tier / confidence columns downstream.

Usage (from the repo root, venv active):
  python ratings/compute_ratings.py                       # dev: reads/writes dev_silver
  python ratings/compute_ratings.py --dataset silver      # prod
  python ratings/compute_ratings.py --dry-run             # compute and summarise, write nothing
"""

from __future__ import annotations

import argparse
import logging
import math
import sys
import time
from dataclasses import dataclass, field

import pandas as pd

DEFAULT_PROJECT = "tennis-predictor-509609"
DEFAULT_DATASET = "dev_silver"
DEFAULT_LOCATION = "EU"
SOURCE_TABLE = "int_tml__player_matches"
TARGET_TABLE = "player_match_ratings"

# Elo
ELO_START = 1500.0
ELO_K_NUMERATOR = 250.0
ELO_K_OFFSET = 5.0
ELO_K_SHAPE = 0.4

# Glicko-2
GLICKO_SCALE = 173.7178
GLICKO_START_RATING = 1500.0
GLICKO_START_RD = 350.0
GLICKO_MAX_RD = 350.0
GLICKO_START_VOL = 0.06
GLICKO_TAU = 0.5            # constrains volatility change; 0.3-1.2 is the usual range
GLICKO_EPSILON = 1e-6

log = logging.getLogger("compute_ratings")


# --------------------------------------------------------------------------------------
# Rating maths (pure functions, no I/O)
# --------------------------------------------------------------------------------------

def elo_expected(r_a: float, r_b: float) -> float:
    """Probability that A beats B."""
    return 1.0 / (1.0 + 10.0 ** ((r_b - r_a) / 400.0))


def elo_k(matches_played: int) -> float:
    return ELO_K_NUMERATOR / (matches_played + ELO_K_OFFSET) ** ELO_K_SHAPE


def _g(phi: float) -> float:
    return 1.0 / math.sqrt(1.0 + 3.0 * phi * phi / (math.pi * math.pi))


def _new_volatility(sigma: float, phi: float, v: float, delta: float) -> float:
    """Glicko-2 step 5: solve for the new volatility (Illinois algorithm)."""
    a = math.log(sigma * sigma)
    tau2 = GLICKO_TAU * GLICKO_TAU

    def f(x: float) -> float:
        ex = math.exp(x)
        num = ex * (delta * delta - phi * phi - v - ex)
        den = 2.0 * (phi * phi + v + ex) ** 2
        return num / den - (x - a) / tau2

    big_a = a
    if delta * delta > phi * phi + v:
        big_b = math.log(delta * delta - phi * phi - v)
    else:
        k = 1
        while f(a - k * GLICKO_TAU) < 0:
            k += 1
        big_b = a - k * GLICKO_TAU

    f_a, f_b = f(big_a), f(big_b)
    for _ in range(100):
        if abs(big_b - big_a) <= GLICKO_EPSILON:
            break
        big_c = big_a + (big_a - big_b) * f_a / (f_b - f_a)
        f_c = f(big_c)
        if f_c * f_b <= 0:
            big_a, f_a = big_b, f_b
        else:
            f_a /= 2.0
        big_b, f_b = big_c, f_c
    return math.exp(big_a / 2.0)


def glicko2_update(rating: float, rd: float, vol: float,
                   opp_rating: float, opp_rd: float, score: float) -> tuple[float, float, float]:
    """One Glicko-2 update for a single game. score: 1 win, 0 loss. Returns (rating, rd, vol)."""
    mu, phi = (rating - 1500.0) / GLICKO_SCALE, rd / GLICKO_SCALE
    mu_j, phi_j = (opp_rating - 1500.0) / GLICKO_SCALE, opp_rd / GLICKO_SCALE

    g_j = _g(phi_j)
    e = 1.0 / (1.0 + math.exp(-g_j * (mu - mu_j)))
    v = 1.0 / (g_j * g_j * e * (1.0 - e))
    delta = v * g_j * (score - e)

    new_vol = _new_volatility(vol, phi, v, delta)
    phi_star = math.sqrt(phi * phi + new_vol * new_vol)
    new_phi = 1.0 / math.sqrt(1.0 / (phi_star * phi_star) + 1.0 / v)
    new_mu = mu + new_phi * new_phi * g_j * (score - e)

    return new_mu * GLICKO_SCALE + 1500.0, min(new_phi * GLICKO_SCALE, GLICKO_MAX_RD), new_vol


def glicko2_inflate_rd(rd: float, vol: float, idle_periods: int) -> float:
    """Grow RD for rating periods (weeks) with no matches: phi^2 + periods * sigma^2."""
    if idle_periods <= 0:
        return rd
    phi = rd / GLICKO_SCALE
    phi = math.sqrt(phi * phi + idle_periods * vol * vol)
    return min(phi * GLICKO_SCALE, GLICKO_MAX_RD)


def glicko2_expected(rating: float, rd: float, opp_rating: float, opp_rd: float) -> float:
    """Win probability accounting for both players' uncertainty."""
    mu, mu_j = (rating - 1500.0) / GLICKO_SCALE, (opp_rating - 1500.0) / GLICKO_SCALE
    phi = math.sqrt((rd / GLICKO_SCALE) ** 2 + (opp_rd / GLICKO_SCALE) ** 2)
    return 1.0 / (1.0 + math.exp(-_g(phi) * (mu - mu_j)))


# --------------------------------------------------------------------------------------
# Rating engine
# --------------------------------------------------------------------------------------

@dataclass
class PlayerState:
    elo: float = ELO_START
    elo_matches: int = 0
    surface_elo: dict = field(default_factory=dict)        # surface -> rating
    surface_matches: dict = field(default_factory=dict)    # surface -> count
    g_rating: float = GLICKO_START_RATING
    g_rd: float = GLICKO_START_RD
    g_vol: float = GLICKO_START_VOL
    last_match_date: pd.Timestamp | None = None


def compute(matches: pd.DataFrame) -> pd.DataFrame:
    """
    matches: one row per completed match, already sorted in time order, with columns
      match_key, winner_id, loser_id, surface, tourney_start_date
    Returns one row per player per match with that player's PRE-match ratings.
    """
    players: dict[str, PlayerState] = {}
    out: list[tuple] = []

    for row in matches.itertuples(index=False):
        w = players.setdefault(row.winner_id, PlayerState())
        l = players.setdefault(row.loser_id, PlayerState())
        surface = row.surface or "unknown"
        date = row.tourney_start_date

        # Days / weeks since each player's previous match (None for a debut)
        def idle(p: PlayerState) -> tuple[int | None, int]:
            if p.last_match_date is None:
                return None, 0
            days = (date - p.last_match_date).days
            return days, max(days // 7 - 1, 0)   # the first week is covered by the update itself

        w_days, w_idle = idle(w)
        l_days, l_idle = idle(l)

        # ---- pre-match state (this is what gets written) ----
        w_rd_pre = glicko2_inflate_rd(w.g_rd, w.g_vol, w_idle)
        l_rd_pre = glicko2_inflate_rd(l.g_rd, l.g_vol, l_idle)
        w_surf_elo = w.surface_elo.get(surface, ELO_START)
        l_surf_elo = l.surface_elo.get(surface, ELO_START)
        w_surf_n = w.surface_matches.get(surface, 0)
        l_surf_n = l.surface_matches.get(surface, 0)

        elo_p_w = elo_expected(w.elo, l.elo)
        surf_p_w = elo_expected(w_surf_elo, l_surf_elo)
        glicko_p_w = glicko2_expected(w.g_rating, w_rd_pre, l.g_rating, l_rd_pre)

        for (pid, p, opp, is_w, days, rd_pre, s_elo, s_n, opp_s_elo, opp_rd_pre, e_p, s_p, g_p) in (
            (row.winner_id, w, l, True,  w_days, w_rd_pre, w_surf_elo, w_surf_n, l_surf_elo, l_rd_pre,
             elo_p_w, surf_p_w, glicko_p_w),
            (row.loser_id,  l, w, False, l_days, l_rd_pre, l_surf_elo, l_surf_n, w_surf_elo, w_rd_pre,
             1 - elo_p_w, 1 - surf_p_w, 1 - glicko_p_w),
        ):
            out.append((
                row.match_key, pid,
                p.elo_matches, s_n, days,
                p.elo, opp.elo, e_p,
                s_elo, opp_s_elo, s_p,
                p.g_rating, rd_pre, p.g_vol, opp.g_rating, opp_rd_pre, g_p,
            ))

        # ---- updates (affect later matches only) ----
        k_w, k_l = elo_k(w.elo_matches), elo_k(l.elo_matches)
        w.elo, l.elo = w.elo + k_w * (1 - elo_p_w), l.elo - k_l * (1 - elo_p_w)
        w.elo_matches += 1
        l.elo_matches += 1

        ks_w, ks_l = elo_k(w_surf_n), elo_k(l_surf_n)
        w.surface_elo[surface] = w_surf_elo + ks_w * (1 - surf_p_w)
        l.surface_elo[surface] = l_surf_elo - ks_l * (1 - surf_p_w)
        w.surface_matches[surface] = w_surf_n + 1
        l.surface_matches[surface] = l_surf_n + 1

        w_new = glicko2_update(w.g_rating, w_rd_pre, w.g_vol, l.g_rating, l_rd_pre, 1.0)
        l_new = glicko2_update(l.g_rating, l_rd_pre, l.g_vol, w.g_rating, w_rd_pre, 0.0)
        w.g_rating, w.g_rd, w.g_vol = w_new
        l.g_rating, l.g_rd, l.g_vol = l_new

        w.last_match_date = l.last_match_date = date

    return pd.DataFrame(out, columns=[
        "match_key", "player_id",
        "matches_played_pre", "surface_matches_played_pre", "days_since_last_match",
        "elo_pre", "opp_elo_pre", "elo_win_prob",
        "surface_elo_pre", "opp_surface_elo_pre", "surface_elo_win_prob",
        "glicko_rating_pre", "glicko_rd_pre", "glicko_vol_pre",
        "opp_glicko_rating_pre", "opp_glicko_rd_pre", "glicko_win_prob",
    ])


# --------------------------------------------------------------------------------------
# BigQuery I/O
# --------------------------------------------------------------------------------------

def read_matches(client, project: str, dataset: str) -> pd.DataFrame:
    # Winner rows only = one row per match. Completed matches only: walkovers, defaults and
    # abandoned matches say nothing about relative strength.
    sql = f"""
        select
            match_key,
            player_id   as winner_id,
            opponent_id as loser_id,
            surface,
            tourney_start_date,
            match_sequence_key
        from `{project}.{dataset}.{SOURCE_TABLE}`
        where is_winner
          and is_completed_match
          and tourney_start_date is not null
        order by match_sequence_key
    """
    df = client.query(sql).result().to_dataframe()
    df["tourney_start_date"] = pd.to_datetime(df["tourney_start_date"])
    return df.sort_values("match_sequence_key", kind="stable").reset_index(drop=True)


def write_ratings(client, project: str, dataset: str, df: pd.DataFrame) -> None:
    from google.cloud import bigquery
    S = bigquery.SchemaField
    schema = [
        S("match_key", "STRING"), S("player_id", "STRING"),
        S("matches_played_pre", "INT64"), S("surface_matches_played_pre", "INT64"),
        S("days_since_last_match", "INT64"),
        S("elo_pre", "FLOAT64"), S("opp_elo_pre", "FLOAT64"), S("elo_win_prob", "FLOAT64"),
        S("surface_elo_pre", "FLOAT64"), S("opp_surface_elo_pre", "FLOAT64"),
        S("surface_elo_win_prob", "FLOAT64"),
        S("glicko_rating_pre", "FLOAT64"), S("glicko_rd_pre", "FLOAT64"), S("glicko_vol_pre", "FLOAT64"),
        S("opp_glicko_rating_pre", "FLOAT64"), S("opp_glicko_rd_pre", "FLOAT64"),
        S("glicko_win_prob", "FLOAT64"),
        S("_computed_at", "TIMESTAMP"),
    ]
    df = df.copy()
    df["days_since_last_match"] = df["days_since_last_match"].astype("Int64")
    df["_computed_at"] = pd.Timestamp.now(tz="UTC")

    table_id = f"{project}.{dataset}.{TARGET_TABLE}"
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,   # full recompute each run
        clustering_fields=["player_id"],
    )
    client.load_table_from_dataframe(df, table_id, job_config=job_config).result()


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Compute pre-match Elo and Glicko-2 ratings.")
    p.add_argument("--project", default=DEFAULT_PROJECT)
    p.add_argument("--dataset", default=DEFAULT_DATASET,
                   help="dataset holding int_tml__player_matches; output is written alongside it")
    p.add_argument("--location", default=DEFAULT_LOCATION)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)

    from google.cloud import bigquery
    client = bigquery.Client(project=args.project, location=args.location)

    t0 = time.time()
    matches = read_matches(client, args.project, args.dataset)
    log.info("Read %d completed matches in %.0fs", len(matches), time.time() - t0)

    t1 = time.time()
    ratings = compute(matches)
    log.info("Computed %d player-match ratings in %.0fs", len(ratings), time.time() - t1)

    # Sanity check: the pre-match favourite should win clearly more often than not
    winners = ratings.iloc[::2]
    log.info("Pre-match favourite won: Elo %.1f%%, surface Elo %.1f%%, Glicko-2 %.1f%%",
             100 * (winners["elo_win_prob"] > 0.5).mean(),
             100 * (winners["surface_elo_win_prob"] > 0.5).mean(),
             100 * (winners["glicko_win_prob"] > 0.5).mean())

    if args.dry_run:
        log.info("Dry run: nothing written.")
        return 0

    write_ratings(client, args.project, args.dataset, ratings)
    log.info("Wrote %s.%s.%s", args.project, args.dataset, TARGET_TABLE)
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())