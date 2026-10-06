-- Each player's form AS OF TODAY, for scoring upcoming matches. Mirrors int_player_form
-- exactly, built from the same int_player_match_stats, in two variants:
--   fresh      : next match is at a NEW tournament. Week windows end today; no tournament workload.
--   continuing : next match is a later round of the player's LATEST tournament. Week windows end
--                before that tournament started; *_this_tourney covers its rounds so far.
-- fct_upcoming_match_features picks the variant per match.

with matches as (

    select * from {{ ref('int_player_match_stats') }}

),

latest_match as (

    select player_id, tour, tourney_id, tourney_name, tourney_day, tourney_date, surface,
           event_date as last_event_date
    from matches
    qualify row_number() over (partition by player_id order by match_sequence_key desc) = 1

),

-- window_end_day plays the role of the "current tournament day" in int_player_form:
-- week windows cover tourney_day in [window_end_day - 364, window_end_day - 1]
variants as (

    select player_id, 'fresh' as form_variant,
           unix_date(current_date()) as window_end_day,
           cast(null as string) as current_tourney_id,
           tour
    from latest_match

    union all

    select player_id, 'continuing',
           tourney_day,
           tourney_id,
           tour
    from latest_match

),

-- Last 10 completed matches (same for both variants: training's last-10 includes earlier rounds)
last_10 as (

    select player_id,
           count(*) as matches_last_10,
           avg(won) as win_rate_last_10
    from (
        select player_id, won
        from matches
        qualify row_number() over (partition by player_id order by match_sequence_key desc) <= 10
    )
    group by player_id

),

windowed as (

    select
        v.player_id,
        v.form_variant,
        v.current_tourney_id,
        m.won,
        m.minutes,
        m.sets_played,
        m.tourney_id,
        m.tour = v.tour and m.tourney_id = v.current_tourney_id               as in_this_tourney,
        m.tourney_day between v.window_end_day - 364 and v.window_end_day - 1 as in_52w,
        m.tourney_day between v.window_end_day - 28  and v.window_end_day - 1 as in_4w,
        m.s_svpt, m.s_1st_in, m.s_1st_won, m.s_2nd_won, m.s_2nd_played,
        m.s_aces, m.s_dfs, m.s_sv_games, m.s_breaks_conceded,
        m.s_bp_saved, m.s_bp_faced, m.s_ret_pts, m.s_ret_won,
        m.s_bp_chances, m.s_bp_converted, m.s_has_stats
    from variants as v
    inner join matches as m using (player_id)

),

aggregated as (

    select
        player_id,
        form_variant,
        any_value(current_tourney_id) as current_tourney_id,

        countif(in_52w)                                   as matches_last_52w,
        avg(if(in_52w, won, null))                        as win_rate_last_52w,

        sum(if(in_52w, s_has_stats, 0))                   as stats_matches_last_52w,
        safe_divide(sum(if(in_52w, s_1st_in, null)),   sum(if(in_52w, s_svpt, null)))        as first_serve_in_pct_52w,
        safe_divide(sum(if(in_52w, s_1st_won, null)),  sum(if(in_52w, s_1st_in, null)))      as first_serve_won_pct_52w,
        safe_divide(sum(if(in_52w, s_2nd_won, null)),  sum(if(in_52w, s_2nd_played, null)))  as second_serve_won_pct_52w,
        safe_divide(sum(if(in_52w, s_1st_won, null)) + sum(if(in_52w, s_2nd_won, null)),
                    sum(if(in_52w, s_svpt, null)))                                           as serve_points_won_pct_52w,
        safe_divide(sum(if(in_52w, s_aces, null)),     sum(if(in_52w, s_svpt, null)))        as ace_rate_52w,
        safe_divide(sum(if(in_52w, s_dfs, null)),      sum(if(in_52w, s_svpt, null)))        as double_fault_rate_52w,
        safe_divide(sum(if(in_52w, s_bp_saved, null)), sum(if(in_52w, s_bp_faced, null)))   as break_points_saved_pct_52w,
        1 - safe_divide(sum(if(in_52w, s_breaks_conceded, null)),
                        sum(if(in_52w, s_sv_games, null)))                                   as service_hold_pct_52w,
        safe_divide(sum(if(in_52w, s_ret_won, null)),  sum(if(in_52w, s_ret_pts, null)))     as return_points_won_pct_52w,
        safe_divide(sum(if(in_52w, s_bp_converted, null)),
                    sum(if(in_52w, s_bp_chances, null)))                                     as break_points_converted_pct_52w,

        countif(in_4w)                                    as matches_last_4w,
        countif(coalesce(in_this_tourney, false))                         as matches_this_tourney,
        coalesce(sum(if(coalesce(in_this_tourney, false), minutes, null)), 0)     as minutes_this_tourney,
        coalesce(sum(if(coalesce(in_this_tourney, false), sets_played, null)), 0) as sets_this_tourney

    from windowed
    group by player_id, form_variant

),

-- Latest known attributes (from any match, completed or not)
profile as (

    select
        player_id,
        player_rank                                            as rank,
        player_rank_points                                     as rank_points,
        player_age + date_diff(current_date(), event_date, day) / 365.25 as age,
        player_height_cm                                       as height_cm,
        coalesce(upper(player_hand) = 'L', false)              as is_left_handed,
        coalesce(upper(player_entry) in ('Q', 'LL'), false)    as latest_is_qualifier,
        coalesce(upper(player_entry) = 'WC', false)            as latest_is_wildcard,
        player_seed                                            as latest_seed,
        tour                                                   as latest_tour,
        tourney_id                                             as latest_tourney_id
    from {{ ref('int_tml__player_matches') }}
    where event_date is not null
    qualify row_number() over (partition by player_id order by match_sequence_key desc) = 1

)

select
    a.player_id,
    a.form_variant,
    l.tour,
    l.tourney_id    as latest_tourney_id,
    l.tourney_name  as latest_tourney_name,
    l.tourney_date  as latest_tourney_date,
    l.surface       as latest_surface,
    l.last_event_date,

    coalesce(t.matches_last_10, 0) as matches_last_10,
    t.win_rate_last_10,
    a.* except (player_id, form_variant, current_tourney_id),

    p.rank,
    p.rank_points,
    p.age,
    p.height_cm,
    p.is_left_handed,
    -- Entry type and seed are only known for the tournament in progress
    if(a.form_variant = 'continuing', p.latest_is_qualifier, false) as is_qualifier,
    if(a.form_variant = 'continuing', p.latest_is_wildcard, false)  as is_wildcard,
    if(a.form_variant = 'continuing', p.latest_seed, null)          as seed

from aggregated as a
inner join latest_match as l using (player_id)
left join last_10 as t using (player_id)
left join profile as p using (player_id)