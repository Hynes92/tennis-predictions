-- A player's first match in the history can't have any matchup or head-to-head history.
-- Any row returned here means future matches are leaking into the features.

with firsts as (

    select player_id, min(match_sequence_key) as first_sequence_key
    from {{ ref('int_player_match_history') }}
    group by 1

)

select f.*
from {{ ref('int_player_matchup_form') }} as f
inner join {{ ref('int_player_match_history') }} as h
    on h.match_key = f.match_key and h.player_id = f.player_id
inner join firsts as x
    on x.player_id = f.player_id and x.first_sequence_key = h.match_sequence_key
where f.vs_left_matches_104w + f.vs_big_server_matches_104w + f.vs_top50_matches_104w
      + f.h2h_matches > 0