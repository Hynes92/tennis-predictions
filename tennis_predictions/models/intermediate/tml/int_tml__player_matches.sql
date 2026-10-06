-- One row per player per match: each match appears twice, once from each player's view.
-- This is the base for every player-level feature (form, ratings, surface records, serve/return).
--
-- Return stats are derived from the opponent's serve stats:
--   return points played = opponent serve points
--   return points won    = opponent serve points - opponent 1st-serve pts won - opponent 2nd-serve pts won

with matches as (

    select
        *,
        -- Matches that shouldn't count as a played result for ratings/form
        regexp_contains(upper(score), r'WEA|ABD|ABN|UNFINISHED|UNP') as is_abandoned
    from {{ ref('int_tml__matches_resolved') }}

),

from_winner as (

    select
        match_key,
        winner_id   as player_id,
        loser_id    as opponent_id,
        winner_name as player_name,
        loser_name  as opponent_name,
        true        as is_winner,

        winner_seed as player_seed,              loser_seed as opponent_seed,
        winner_entry as player_entry,            loser_entry as opponent_entry,
        winner_hand as player_hand,              loser_hand as opponent_hand,
        winner_height_cm as player_height_cm,    loser_height_cm as opponent_height_cm,
        winner_ioc as player_ioc,                loser_ioc as opponent_ioc,
        winner_age as player_age,                loser_age as opponent_age,
        winner_rank as player_rank,              loser_rank as opponent_rank,
        winner_rank_points as player_rank_points, loser_rank_points as opponent_rank_points,
        winner_id_source as player_id_source,

        w_aces as aces,                          l_aces as opp_aces,
        w_double_faults as double_faults,        l_double_faults as opp_double_faults,
        w_serve_points as serve_points,          l_serve_points as opp_serve_points,
        w_first_serves_in as first_serves_in,    l_first_serves_in as opp_first_serves_in,
        w_first_serve_points_won as first_serve_points_won,
        l_first_serve_points_won as opp_first_serve_points_won,
        w_second_serve_points_won as second_serve_points_won,
        l_second_serve_points_won as opp_second_serve_points_won,
        w_service_games as service_games,        l_service_games as opp_service_games,
        w_break_points_saved as break_points_saved,
        l_break_points_saved as opp_break_points_saved,
        w_break_points_faced as break_points_faced,
        l_break_points_faced as opp_break_points_faced

    from matches

),

from_loser as (

    select
        match_key,
        loser_id    as player_id,
        winner_id   as opponent_id,
        loser_name  as player_name,
        winner_name as opponent_name,
        false       as is_winner,

        loser_seed, winner_seed,
        loser_entry, winner_entry,
        loser_hand, winner_hand,
        loser_height_cm, winner_height_cm,
        loser_ioc, winner_ioc,
        loser_age, winner_age,
        loser_rank, winner_rank,
        loser_rank_points, winner_rank_points,
        loser_id_source,

        l_aces, w_aces,
        l_double_faults, w_double_faults,
        l_serve_points, w_serve_points,
        l_first_serves_in, w_first_serves_in,
        l_first_serve_points_won, w_first_serve_points_won,
        l_second_serve_points_won, w_second_serve_points_won,
        l_service_games, w_service_games,
        l_break_points_saved, w_break_points_saved,
        l_break_points_faced, w_break_points_faced

    from matches

),

-- union all matches columns by position, so from_loser lists them in from_winner's order
player_rows as (

    select * from from_winner
    union all
    select * from from_loser

),

final as (

    select
        -- keys
        p.match_key,
        p.player_id,
        p.opponent_id,
        p.player_name,
        p.opponent_name,
        p.player_id_source,

        -- match context
        m.source_dataset,
        m.tour,
        m.competition_level,
        m.tourney_id,
        m.tourney_name,
        m.tourney_level_raw,
        m.surface,
        m.is_indoor,
        m.draw_size,
        m.best_of,
        m.tourney_start_date,
        m.round,
        m.round_order,
        m.match_num,

        -- Sortable position of this match in time. TML has no per-match date, so:
        -- tournament week, then round (qualifying before main draw), then match number.
        format('%s|%02d|%s|%05d',
            cast(m.tourney_start_date as string),
            coalesce(m.round_order, 99),
            m.tourney_id,
            coalesce(m.match_num, 0)
        ) as match_sequence_key,

        -- result
        p.is_winner,
        m.score,
        m.minutes,
        m.is_walkover,
        m.is_retirement,
        m.is_default,
        m.is_abandoned,
        not (m.is_walkover or m.is_default or m.is_abandoned) as is_completed_match,
        m.has_serve_stats,

        -- player and opponent attributes at match time
        p.player_seed, p.opponent_seed,
        p.player_entry, p.opponent_entry,
        p.player_hand, p.opponent_hand,
        p.player_height_cm, p.opponent_height_cm,
        p.player_ioc, p.opponent_ioc,
        p.player_age, p.opponent_age,
        p.player_rank, p.opponent_rank,
        p.player_rank_points, p.opponent_rank_points,

        -- serve stats (player)
        p.aces,
        p.double_faults,
        p.serve_points,
        p.first_serves_in,
        p.first_serve_points_won,
        p.second_serve_points_won,
        p.service_games,
        p.break_points_saved,
        p.break_points_faced,

        -- serve stats (opponent)
        p.opp_aces,
        p.opp_double_faults,
        p.opp_serve_points,
        p.opp_first_serves_in,
        p.opp_first_serve_points_won,
        p.opp_second_serve_points_won,
        p.opp_service_games,
        p.opp_break_points_saved,
        p.opp_break_points_faced,

        -- return stats (derived from the opponent's serve)
        p.opp_serve_points as return_points,
        p.opp_serve_points
            - p.opp_first_serve_points_won
            - p.opp_second_serve_points_won as return_points_won,
        p.opp_break_points_faced as break_point_chances,
        p.opp_break_points_faced - p.opp_break_points_saved as break_points_converted

    from player_rows as p
    inner join matches as m using (match_key)

)

select * from final