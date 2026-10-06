-- Every match must appear exactly twice in int_tml__player_matches: once per player.
-- Returns the offending matches; the test passes when no rows come back.
select match_key, count(*) as player_rows
from {{ ref('int_tml__player_matches') }}
group by match_key
having count(*) != 2