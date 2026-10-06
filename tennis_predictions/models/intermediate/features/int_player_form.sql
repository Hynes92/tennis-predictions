-- Rolling form, serve/return and workload features for every player before every completed match.
-- Per-match building blocks come from int_player_match_stats, shared with the live features
-- (int_player_current_form) so training and scoring use identical definitions.
--
-- POINT-IN-TIME RULE: every feature uses only matches strictly before this one.
--   * "last N matches" windows: the player's previous N completed matches (by match_sequence_key),
--     which includes earlier rounds of the current tournament.
--   * week-based windows (4 / 52 / 104 weeks): end the day before the current tournament starts.
--     Earlier rounds of the current tournament are covered by the *_this_tourney features.

with with_keys as (

    select * from {{ ref('int_player_match_stats') }}

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