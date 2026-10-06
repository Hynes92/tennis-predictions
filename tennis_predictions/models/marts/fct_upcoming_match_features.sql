-- Upcoming Betfair singles matches with the SAME feature columns as fct_match_features,
-- built from each player's current state, ready for the trained model to score.
--   A = Betfair runner 1, B = runner 2.
--   Tournament details (surface, indoor, best-of) come from the most recent TML edition of the
--   same tournament (matched by city word, or by name for Grand Slams).
--   Form variant per player: 'continuing' if their latest TML tournament is this event's TML
--   edition within the last 21 days, else 'fresh'.
-- market_prob_a is a benchmark only and is never used as a feature.

{% set side_features = match_side_features() %}
{% set diff_features = match_diff_features() %}
{% set generic_words = "('open','masters','cup','championships','championship','international',
                         'tennis','classic','trophy','grand','prix','series','ladies','mens',
                         'womens','tour','final','finals')" %}

with upcoming as (

    select * from {{ ref('int_betfair__upcoming_matches') }}

),

player_map as (

    select selection_id, tml_player_id, tour as mapped_tour, match_method
    from {{ ref('int_betfair__player_map') }}

),

matches as (

    select
        u.*,
        pa.tml_player_id as player_a_id,
        pb.tml_player_id as player_b_id,
        coalesce(pa.match_method, 'unmatched') as a_match_method,
        coalesce(pb.match_method, 'unmatched') as b_match_method,
        coalesce(u.tour_hint, pa.mapped_tour, pb.mapped_tour) as tour,
        -- ITF isn't in the training data; the closest trained level is challenger
        if(u.competition_level = 'itf', 'challenger', u.competition_level) as model_competition_level,
        case
            when regexp_contains(lower(u.competition_name), r'australian open')            then 'australian open'
            when regexp_contains(lower(u.competition_name), r'french open|roland garros')  then 'roland garros'
            when regexp_contains(lower(u.competition_name), r'wimbledon')                  then 'wimbledon'
            when regexp_contains(lower(u.competition_name), r'us open')                    then 'us open'
        end as slam_key,
        array(
            select w
            from unnest(split({{ normalize_player_name(
                "regexp_replace(lower(u.competition_name), r'\\b(atp|wta|itf|challenger|[mw]\\d{2,3}|\\d{4})\\b', ' ')"
            ) }}, ' ')) as w
            where char_length(w) >= 4 and w not in {{ generic_words }}
        ) as comp_words
    from upcoming as u
    left join player_map as pa on pa.selection_id = u.runner_1_selection_id
    left join player_map as pb on pb.selection_id = u.runner_2_selection_id

),

-- Recent TML tournament editions, with their surface / indoor / best-of
tml_event_rollup as (

    select
        tour,
        tourney_id,
        any_value(tourney_name)                                    as tourney_name,
        max(tourney_date)                                          as tourney_date,
        approx_top_count(surface, 1)[safe_offset(0)].value         as surface,
        approx_top_count(is_indoor, 1)[safe_offset(0)].value       as is_indoor,
        max(best_of)                                               as best_of,
        any_value(if(competition_level = 'qualifying', 'main_tour', competition_level)) as level
    from {{ ref('int_tml__player_matches') }}
    where tourney_date >= date_sub(current_date(), interval 400 day)
    group by tour, tourney_id

),

tml_events as (

    select
        *,
        case
            when regexp_contains(lower(tourney_name), r'australian open')           then 'australian open'
            when regexp_contains(lower(tourney_name), r'french open|roland garros') then 'roland garros'
            when regexp_contains(lower(tourney_name), r'wimbledon')                 then 'wimbledon'
            when regexp_contains(lower(tourney_name), r'us open')                   then 'us open'
        end                                                        as slam_key,
        array(
            select w
            from unnest(split({{ normalize_player_name('tourney_name') }}, ' ')) as w
            where char_length(w) >= 4 and w not in {{ generic_words }}
        )                                                          as name_words
    from tml_event_rollup

),

event_match as (

    select
        m.market_id,
        e.tourney_id    as tml_tourney_id,
        e.tourney_name  as tml_tourney_name,
        e.tourney_date  as tml_tourney_date,
        e.surface,
        e.is_indoor,
        e.best_of
    from matches as m
    inner join tml_events as e
        on e.tour = m.tour
    where (m.slam_key is not null and m.slam_key = e.slam_key)
       or (m.slam_key is null and exists (
               select 1 from unnest(m.comp_words) as w where w in unnest(e.name_words)))
    qualify row_number() over (
        partition by m.market_id
        order by (e.level = m.model_competition_level) desc, e.tourney_date desc
    ) = 1

),

match_context as (

    select
        m.*,
        em.tml_tourney_id,
        em.tml_tourney_name,
        em.tml_tourney_date,
        em.surface,
        em.is_indoor,
        coalesce(em.best_of, 3) as best_of
    from matches as m
    left join event_match as em using (market_id)

),

-- One row per player per upcoming match, with every per-side feature
sides as (

    select
        c.market_id,
        s.side,
        s.player_id,
        if(cf_latest.latest_tourney_id = c.tml_tourney_id
           and cf_latest.latest_tourney_date >= date_sub(current_date(), interval 21 day),
           'continuing', 'fresh') as form_variant
    from match_context as c
    cross join unnest([
        struct('a' as side, c.player_a_id as player_id),
        struct('b' as side, c.player_b_id as player_id)
    ]) as s
    left join {{ ref('int_player_current_form') }} as cf_latest
        on cf_latest.player_id = s.player_id and cf_latest.form_variant = 'fresh'

),

side_features as (

    select
        sd.market_id,
        sd.side,
        sd.player_id,
        sd.form_variant,

        -- ratings (current = pre-match for the next match)
        r.elo                                               as elo_pre,
        case c.surface
            when 'hard'   then r.surface_elo_hard
            when 'clay'   then r.surface_elo_clay
            when 'grass'  then r.surface_elo_grass
            when 'carpet' then r.surface_elo_carpet
        end                                                 as surface_elo_pre,
        r.glicko_rating                                     as glicko_rating_pre,
        r.glicko_rd                                         as glicko_rd_pre,
        r.matches_played                                    as matches_played_pre,
        case c.surface
            when 'hard'   then r.surface_matches_hard
            when 'clay'   then r.surface_matches_clay
            when 'grass'  then r.surface_matches_grass
            when 'carpet' then r.surface_matches_carpet
        end                                                 as surface_matches_played_pre,
        r.days_since_last_match,

        -- form and profile
        f.rank, f.rank_points, f.age, f.height_cm, f.is_left_handed,
        f.is_qualifier, f.is_wildcard, f.seed,
        f.matches_last_10, f.win_rate_last_10,
        f.matches_last_52w, f.win_rate_last_52w,
        coalesce(sf.surface_matches_last_52w, 0)            as surface_matches_last_52w,
        sf.surface_win_rate_last_52w,
        coalesce(sf.surface_matches_last_104w, 0)           as surface_matches_last_104w,
        f.stats_matches_last_52w,
        f.first_serve_in_pct_52w, f.first_serve_won_pct_52w, f.second_serve_won_pct_52w,
        f.serve_points_won_pct_52w, f.ace_rate_52w, f.double_fault_rate_52w,
        f.break_points_saved_pct_52w, f.service_hold_pct_52w,
        f.return_points_won_pct_52w, f.break_points_converted_pct_52w,
        f.matches_last_4w, f.matches_this_tourney, f.minutes_this_tourney, f.sets_this_tourney

    from sides as sd
    inner join match_context as c using (market_id)
    left join {{ source('ratings', 'player_current_ratings') }} as r
        on r.player_id = sd.player_id
    left join {{ ref('int_player_current_form') }} as f
        on f.player_id = sd.player_id and f.form_variant = sd.form_variant
    left join {{ ref('int_player_current_surface_form') }} as sf
        on sf.player_id = sd.player_id and sf.form_variant = sd.form_variant and sf.surface = c.surface

),

final as (

    select
        -- market and match context
        c.market_id,
        c.snapshot_at,
        c.market_start_time,
        c.competition_name,
        c.event_name,
        c.tour,
        c.model_competition_level                         as competition_level,
        c.tml_tourney_name,
        c.surface,
        c.is_indoor,
        c.best_of,
        c.runner_1_name                                   as player_a_name,
        c.runner_2_name                                   as player_b_name,
        c.runner_1_selection_id                           as a_selection_id,
        c.runner_2_selection_id                           as b_selection_id,
        c.player_a_id,
        c.player_b_id,
        c.a_match_method,
        c.b_match_method,
        a.form_variant                                    as a_form_variant,
        b.form_variant                                    as b_form_variant,

        -- market benchmark (never a feature)
        c.market_prob_runner_1                            as market_prob_a,
        c.runner_1_back_price                             as a_back_price,
        c.runner_2_back_price                             as b_back_price,
        c.total_matched,

        -- rating-based win probabilities for A (same formulas as ratings/compute_ratings.py)
        1 / (1 + pow(10, (b.elo_pre - a.elo_pre) / 400))                 as elo_win_prob_a,
        1 / (1 + pow(10, (b.surface_elo_pre - a.surface_elo_pre) / 400)) as surface_elo_win_prob_a,
        1 / (1 + exp(
            -(1 / sqrt(1 + 3 * (pow(a.glicko_rd_pre / 173.7178, 2) + pow(b.glicko_rd_pre / 173.7178, 2))
                          / pow(acos(-1), 2)))
            * ((a.glicko_rating_pre - b.glicko_rating_pre) / 173.7178)
        ))                                                               as glicko_win_prob_a,

        -- per-side features
        {%- for f in side_features %}
        a.{{ f }} as a_{{ f }},
        b.{{ f }} as b_{{ f }},
        {%- endfor %}

        -- A minus B differences
        {%- for f in diff_features %}
        a.{{ f }} - b.{{ f }} as diff_{{ f }},
        {%- endfor %}
        safe.ln(b.rank) - safe.ln(a.rank) as diff_log_rank,

        -- data sufficiency (same rules as fct_match_features, plus 'none' for unmapped players)
        least(a.matches_last_52w, b.matches_last_52w)                   as min_matches_last_52w,
        least(a.surface_matches_last_104w, b.surface_matches_last_104w) as min_surface_matches_last_104w,
        greatest(a.glicko_rd_pre, b.glicko_rd_pre)                      as max_glicko_rd,
        case
            when c.player_a_id is null or c.player_b_id is null              then 'none'
            when least(a.matches_played_pre, b.matches_played_pre) < 5
              or least(a.matches_last_52w, b.matches_last_52w) < 5           then 'thin'
            when least(a.matches_last_52w, b.matches_last_52w) >= 20
             and least(a.surface_matches_last_104w, b.surface_matches_last_104w) >= 5 then 'full'
            else 'partial'
        end as data_tier

    from match_context as c
    inner join side_features as a on a.market_id = c.market_id and a.side = 'a'
    inner join side_features as b on b.market_id = c.market_id and b.side = 'b'

)

select * from final