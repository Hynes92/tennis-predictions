-- One row per player per completed match, with the per-match building blocks shared by
-- the training features (int_player_form) and the live features (int_player_current_form).
-- Keeping these definitions in ONE place prevents train/serve skew.

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

)

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