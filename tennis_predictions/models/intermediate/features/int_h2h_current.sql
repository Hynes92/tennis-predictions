-- Head-to-head AS OF TODAY for every pair that has met (since 2005), from each player's side.
-- Same definitions as int_player_matchup_form. Pairs that never met: h2h_matches = 0,
-- h2h_over_expected = 0, h2h_last_won = null when joining, as training does.

select
    player_id,
    opponent_id,
    count(*)                                                                as h2h_matches,
    sum(over_expected) / (count(*) + 2)                                     as h2h_over_expected,
    array_agg(won order by match_sequence_key desc limit 1)[offset(0)]      as h2h_last_won
from {{ ref('int_player_match_history') }}
group by 1, 2