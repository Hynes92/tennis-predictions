-- One row per player per completed match: the result against Elo's expectation, and what
-- kind of opponent it was AT THE TIME (left-handed / big server / top 50).
-- Building block for the matchup and head-to-head features.

{{ config(materialized='table') }}

with matches as (

    select
        s.match_key,
        s.player_id,
        s.opponent_id,
        s.tour,
        s.tourney_date,
        s.match_sequence_key,
        cast(s.is_winner as int64)                          as won,
        coalesce(upper(s.opponent_hand) = 'L', false)       as opp_is_left,
        coalesce(s.opponent_rank <= 50, false)              as opp_is_top50
    from {{ ref('int_player_match_stats') }} as s
    where s.is_completed_match
      and s.tourney_date >= '2005-01-01'

),

-- each player's pre-match 52-week ace rate (already point-in-time in int_player_form)
serve_form as (

    select match_key, player_id, ace_rate_52w
    from {{ ref('int_player_form') }}

),

-- "Big server" = opponent's ace rate in the top quartile of the PREVIOUS season on that
-- tour, so the threshold never uses matches from the future.
big_server_threshold as (

    select
        m.tour,
        extract(year from m.tourney_date) + 1               as applies_to_year,
        approx_quantiles(f.ace_rate_52w, 4)[offset(3)]      as ace_rate_q3
    from matches as m
    inner join serve_form as f
        on f.match_key = m.match_key and f.player_id = m.player_id
    where f.ace_rate_52w is not null
    group by 1, 2

)

select
    m.*,
    r.elo_win_prob                                          as expected_win,
    m.won - r.elo_win_prob                                  as over_expected,
    coalesce(o.ace_rate_52w >= t.ace_rate_q3, false)        as opp_is_big_server
from matches as m
inner join {{ source('ratings', 'player_match_ratings') }} as r
    on r.match_key = m.match_key and r.player_id = m.player_id
left join serve_form as o
    on o.match_key = m.match_key and o.player_id = m.opponent_id
left join big_server_threshold as t
    on t.tour = m.tour and t.applies_to_year = extract(year from m.tourney_date)