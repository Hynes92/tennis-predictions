-- Both players in a match must see the same number of previous meetings.

select a.match_key, a.player_id, a.h2h_matches, b.player_id as other_id, b.h2h_matches as other_h2h
from {{ ref('int_player_matchup_form') }} as a
inner join {{ ref('int_player_matchup_form') }} as b
    on b.match_key = a.match_key and b.player_id > a.player_id
where a.h2h_matches != b.h2h_matches