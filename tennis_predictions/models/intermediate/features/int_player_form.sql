-- Rolling form, serve/return and workload features for every player before every completed match.
--
-- POINT-IN-TIME RULE: every feature uses only matches strictly before this one.
--   * "last N matches" windows: the player's previous N completed matches (by match_sequence_key),
--     which includes earlier rounds of the current tournament.
--   * week-based windows (4 / 52 / 104 weeks): end the day before the CURRENT TOURNAMENT starts
--     (tourney_date). match_sequence_key is also ordered by tourney_date first, so the windows
--     and the ordering always agree. Earlier rounds of the current tournament are covered by the
--     *_this_tourney workload features instead.
--
-- Only completed matches are used (no walkovers, defaults or abandoned matches).
-- Serve/return stats are only used when internally consistent (stats_ok).
-- Rates are sum(numerator) / sum(denominator) over the window, so long matches weigh more,
-- and they are NULL (not 0) when the window has no data.

with player_matches as (

    select
        *,
        -- Only trust serve/return stats that are internally consistent for both players
        has_serve_stats
            and serve_points >= first_serves_in
            and first_serves_in >= first_serve_points_won
            and serve_points - first_serves_in >= second_serve_points_won
            and break_points_faced >= break_points_saved
            and opp_serve_points >= opp_first_serves_in
            and opp_first_serves_in >= opp_first_serve_points_won
            and opp_serve_points - opp_first_serves_in >= opp_second_serve_points_won
            and opp_break_points_faced >= opp_break_points_saved
            as stats_ok
    from {{ ref('int_tml__player_matches') }}
    where is_completed_match
      and event_date is not null

),

with_keys as (

    select
        *,
        if(is_winner, 1, 0) as won,

        -- Tournament date as a day number for RANGE windows
        unix_date(tourney_date) as tourney_day,

        -- Sets played, parsed from the score ("6-4 3-6 7-6(5)" -> 3)
        (select count(*) from unnest(split(score, ' ')) as s
         where regexp_contains(s, r'^\d+-\d+')) as sets_played,

        -- Serve/return components, only where the match has consistent stats
        if(stats_ok, serve_points, null)                                 as s_svpt,
        if(stats_ok, first_serves_in, null)                              as s_1st_in,
        if(stats_ok, first_serve_points_won, null)                       as s_1st_won,
        if(stats_ok, second_serve_points_won, null)                      as s_2nd_won,
        if(stats_ok, serve_points - first_serves_in, null)               as s_2nd_played,
        if(stats_ok, aces, null)                                         as s_aces,
        if(stats_ok, double_faults, null)                                as s_dfs,
        if(stats_ok, service_games, null)                                as s_sv_games,
        if(stats_ok, break_points_faced - break_points_saved, null)      as s_breaks_conceded,
        if(stats_ok, break_points_saved, null)                           as s_bp_saved,
        if(stats_ok, break_points_faced, null)                           as s_bp_faced,
        if(stats_ok, return_points, null)                                as s_ret_pts,
        if(stats_ok, return_points_won, null)                            as s_ret_won,
        if(stats_ok, break_point_chances, null)                          as s_bp_chances,
        if(stats_ok, break_points_converted, null)                       as s_bp_converted,
        if(stats_ok, 1, 0)                                               as s_has_stats

    from player_matches

),

features as (

    select
        -- keys and context
        match_key,
        player_id,
        opponent_id,
        tour,
        competition_level,
        surface,
        event_date,
        tourney_date,
        tourney_id,
        round_order,
        match_sequence_key,

        -- ---------- results form ----------
        count(*)  over last_10                                   as matches_last_10,
        avg(won)  over last_10                                   as win_rate_last_10,

        count(*)  over weeks_52                                  as matches_last_52w,
        avg(won)  over weeks_52                                  as win_rate_last_52w,

        count(*)  over surface_52w                               as surface_matches_last_52w,
        avg(won)  over surface_52w                               as surface_win_rate_last_52w,
        count(*)  over surface_104w                              as surface_matches_last_104w,

        -- ---------- serve (last 52 weeks) ----------
        sum(s_has_stats) over weeks_52                           as stats_matches_last_52w,
        safe_divide(sum(s_1st_in)   over weeks_52, sum(s_svpt)       over weeks_52) as first_serve_in_pct_52w,
        safe_divide(sum(s_1st_won)  over weeks_52, sum(s_1st_in)     over weeks_52) as first_serve_won_pct_52w,
        safe_divide(sum(s_2nd_won)  over weeks_52, sum(s_2nd_played) over weeks_52) as second_serve_won_pct_52w,
        safe_divide(sum(s_1st_won)  over weeks_52 + sum(s_2nd_won) over weeks_52,
                    sum(s_svpt)     over weeks_52)                                  as serve_points_won_pct_52w,
        safe_divide(sum(s_aces)     over weeks_52, sum(s_svpt)       over weeks_52) as ace_rate_52w,
        safe_divide(sum(s_dfs)      over weeks_52, sum(s_svpt)       over weeks_52) as double_fault_rate_52w,
        safe_divide(sum(s_bp_saved) over weeks_52, sum(s_bp_faced)   over weeks_52) as break_points_saved_pct_52w,
        1 - safe_divide(sum(s_breaks_conceded) over weeks_52,
                        sum(s_sv_games)        over weeks_52)                       as service_hold_pct_52w,

        -- ---------- return (last 52 weeks) ----------
        safe_divide(sum(s_ret_won)      over weeks_52, sum(s_ret_pts)      over weeks_52) as return_points_won_pct_52w,
        safe_divide(sum(s_bp_converted) over weeks_52, sum(s_bp_chances)   over weeks_52) as break_points_converted_pct_52w,

        -- ---------- workload ----------
        count(*)      over weeks_4                               as matches_last_4w,
        coalesce(count(*)          over this_tourney, 0)         as matches_this_tourney,
        coalesce(sum(minutes)      over this_tourney, 0)         as minutes_this_tourney,
        coalesce(sum(sets_played)  over this_tourney, 0)         as sets_this_tourney

    from with_keys

    window
        last_10      as (partition by player_id
                         order by match_sequence_key
                         rows between 10 preceding and 1 preceding),
        weeks_52     as (partition by player_id
                         order by tourney_day
                         range between 364 preceding and 1 preceding),
        weeks_4      as (partition by player_id
                         order by tourney_day
                         range between 28 preceding and 1 preceding),
        surface_52w  as (partition by player_id, surface
                         order by tourney_day
                         range between 364 preceding and 1 preceding),
        surface_104w as (partition by player_id, surface
                         order by tourney_day
                         range between 728 preceding and 1 preceding),
        this_tourney as (partition by player_id, tour, tourney_id
                         order by match_sequence_key
                         rows between unbounded preceding and 1 preceding)

)

select * from features