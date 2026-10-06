-- One row per completed match, oriented as player A vs player B, with pre-match features for
-- both players, A-minus-B differences, the label (a_won) and training/data-sufficiency flags.
--
-- Orientation: a hash of match_key decides whether the winner is A or B, giving a ~50/50 label
-- split that is identical on every rebuild (see tests/assert_label_balance.sql).
-- Every feature is pre-match (see int_player_form and ratings/compute_ratings.py).

{% set side_features = [
    'elo_pre', 'surface_elo_pre', 'glicko_rating_pre', 'glicko_rd_pre',
    'matches_played_pre', 'surface_matches_played_pre', 'days_since_last_match',
    'rank', 'rank_points', 'age', 'height_cm', 'is_left_handed', 'is_qualifier', 'is_wildcard', 'seed',
    'matches_last_10', 'win_rate_last_10',
    'matches_last_52w', 'win_rate_last_52w',
    'surface_matches_last_52w', 'surface_win_rate_last_52w', 'surface_matches_last_104w',
    'stats_matches_last_52w',
    'first_serve_in_pct_52w', 'first_serve_won_pct_52w', 'second_serve_won_pct_52w',
    'serve_points_won_pct_52w', 'ace_rate_52w', 'double_fault_rate_52w',
    'break_points_saved_pct_52w', 'service_hold_pct_52w',
    'return_points_won_pct_52w', 'break_points_converted_pct_52w',
    'matches_last_4w', 'matches_this_tourney', 'minutes_this_tourney', 'sets_this_tourney',
] %}

{% set side_features = [
    'elo_pre', 'surface_elo_pre', 'glicko_rating_pre', 'age', 'height_cm',
    'win_rate_last_10', 'win_rate_last_52w', 'surface_win_rate_last_52w',
    'serve_points_won_pct_52w', 'return_points_won_pct_52w',
    'service_hold_pct_52w', 'break_points_converted_pct_52w',
    'matches_last_4w', 'minutes_this_tourney', 'sets_this_tourney',
] %}

with matches as (

    -- One row per completed match (the winner's row), with match context
    select
        match_key,
        tour,
        competition_level,
        source_dataset,
        tourney_id,
        tourney_name,
        tourney_level_raw,
        tourney_date,
        event_date,
        surface,
        is_indoor,
        best_of,
        round,
        round_order,
        match_sequence_key,
        player_id   as winner_id,
        opponent_id as loser_id,
        mod(abs(farm_fingerprint(match_key)), 2) = 0 as winner_is_a
    from {{ ref('int_tml__player_matches') }}
    where is_winner
      and is_completed_match

),

-- Everything we know about one player going into one match
player_side as (

    select
        pm.match_key,
        pm.player_id,
        pm.player_id_source,

        -- ratings (pre-match)
        r.elo_pre,
        r.surface_elo_pre,
        r.glicko_rating_pre,
        r.glicko_rd_pre,
        r.matches_played_pre,
        r.surface_matches_played_pre,
        r.days_since_last_match,
        r.elo_win_prob,
        r.surface_elo_win_prob,
        r.glicko_win_prob,

        -- attributes at match time
        pm.player_rank                                         as rank,
        pm.player_rank_points                                  as rank_points,
        pm.player_age                                          as age,
        pm.player_height_cm                                    as height_cm,
        coalesce(upper(pm.player_hand) = 'L', false)           as is_left_handed,
        coalesce(upper(pm.player_entry) in ('Q', 'LL'), false) as is_qualifier,
        coalesce(upper(pm.player_entry) = 'WC', false)         as is_wildcard,
        pm.player_seed                                         as seed,

        -- rolling form (pre-match)
        f.* except (match_key, player_id, opponent_id, tour, competition_level, surface,
                    event_date, tourney_date, tourney_id, round_order, match_sequence_key)

    from {{ ref('int_tml__player_matches') }} as pm
    inner join {{ ref('int_player_form') }} as f
        on f.match_key = pm.match_key and f.player_id = pm.player_id
    inner join {{ source('ratings', 'player_match_ratings') }} as r
        on r.match_key = pm.match_key and r.player_id = pm.player_id

),

oriented as (

    select
        *,
        if(winner_is_a, winner_id, loser_id) as player_a_id,
        if(winner_is_a, loser_id, winner_id) as player_b_id,
        if(winner_is_a, 1, 0)                as a_won
    from matches

),

final as (

    select
        -- keys and context
        m.match_key,
        m.tour,
        m.competition_level,
        m.source_dataset,
        m.tourney_id,
        m.tourney_name,
        m.tourney_level_raw,
        m.tourney_date,
        m.event_date,
        m.surface,
        m.is_indoor,
        m.best_of,
        m.round,
        m.round_order,
        m.match_sequence_key,
        m.player_a_id,
        m.player_b_id,

        -- label
        m.a_won,

        -- rating-based win probabilities for A (baselines to beat)
        a.elo_win_prob         as elo_win_prob_a,
        a.surface_elo_win_prob as surface_elo_win_prob_a,
        a.glicko_win_prob      as glicko_win_prob_a,

        -- per-side features
        {%- for f in side_features %}
        a.{{ f }} as a_{{ f }},
        b.{{ f }} as b_{{ f }},
        {%- endfor %}

        -- A minus B differences
        {%- for f in diff_features %}
        a.{{ f }} - b.{{ f }} as diff_{{ f }},
        {%- endfor %}
        -- rank is better when lower, so log(B) - log(A) is positive when A is ranked higher
        safe.ln(b.rank) - safe.ln(a.rank) as diff_log_rank,

        -- data sufficiency
        least(a.matches_last_52w, b.matches_last_52w)                   as min_matches_last_52w,
        least(a.surface_matches_last_104w, b.surface_matches_last_104w) as min_surface_matches_last_104w,
        greatest(a.glicko_rd_pre, b.glicko_rd_pre)                      as max_glicko_rd,
        case
            when least(a.matches_played_pre, b.matches_played_pre) < 5
              or least(a.matches_last_52w, b.matches_last_52w) < 5          then 'thin'
            when least(a.matches_last_52w, b.matches_last_52w) >= 20
             and least(a.surface_matches_last_104w, b.surface_matches_last_104w) >= 5 then 'full'
            else 'partial'
        end as data_tier,
        a.player_id_source as a_id_source,
        b.player_id_source as b_id_source,

        -- training filters (the training script filters on is_training_eligible)
        regexp_contains(lower(m.tourney_name), r'laver cup') as is_exhibition,
        m.tourney_date >= '2010-01-01'
            and not regexp_contains(lower(m.tourney_name), r'laver cup') as is_training_eligible

    from oriented as m
    inner join player_side as a
        on a.match_key = m.match_key and a.player_id = m.player_a_id
    inner join player_side as b
        on b.match_key = m.match_key and b.player_id = m.player_b_id

)

select * from final