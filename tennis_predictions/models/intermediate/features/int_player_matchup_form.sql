-- Point-in-time matchup features for TRAINING: for each player in each match, using only
-- that player's earlier matches (match_sequence_key strictly before):
--   * results vs expectation against left-handers / big servers / top-50 players (104 weeks)
--   * head-to-head against this opponent (all earlier meetings since 2005)
-- "over_expected" = wins minus Elo-expected wins, shrunk towards 0 for small samples
-- (divided by n + 5, or n + 2 for head-to-head), so a 1-0 record isn't treated as certain.

{{ config(materialized='table') }}

with history as (

    select * from {{ ref('int_player_match_history') }}

),

targets as (

    select match_key, player_id, opponent_id, tourney_date, match_sequence_key
    from history
    where tourney_date >= '2009-01-01'

),

style as (

    select
        t.match_key,
        t.player_id,
        {% for kind in ['left', 'big_server', 'top50'] %}
        countif(p.opp_is_{{ kind }})                                        as vs_{{ kind }}_matches_104w,
        sum(if(p.opp_is_{{ kind }}, p.over_expected, 0))
            / (countif(p.opp_is_{{ kind }}) + 5)                            as vs_{{ kind }}_over_expected_104w,
        {% endfor %}
    from targets as t
    left join history as p
        on p.player_id = t.player_id
        and p.match_sequence_key < t.match_sequence_key
        and p.tourney_date >= date_sub(t.tourney_date, interval 104 week)
    group by 1, 2

),

head_to_head as (

    select
        t.match_key,
        t.player_id,
        count(p.match_key)                                                  as h2h_matches,
        coalesce(sum(p.over_expected), 0) / (count(p.match_key) + 2)        as h2h_over_expected,
        array_agg(p.won ignore nulls order by p.match_sequence_key desc limit 1)[safe_offset(0)]
                                                                            as h2h_last_won
    from targets as t
    left join history as p
        on p.player_id = t.player_id
        and p.opponent_id = t.opponent_id
        and p.match_sequence_key < t.match_sequence_key
    group by 1, 2

)

select
    s.*,
    h.h2h_matches,
    h.h2h_over_expected,
    h.h2h_last_won
from style as s
inner join head_to_head as h
    on h.match_key = s.match_key and h.player_id = s.player_id