-- Point-in-time check: on a player's first-ever completed match there is no earlier history,
-- so every look-back feature must be empty. Any row returned means the windows leak.
with first_matches as (
    select *
    from {{ ref('int_player_form') }}
    qualify row_number() over (partition by player_id order by match_sequence_key) = 1
)
select match_key, player_id, matches_last_10, matches_last_52w, matches_last_4w, matches_this_tourney
from first_matches
where matches_last_10 > 0
   or matches_last_52w > 0
   or matches_last_4w > 0
   or matches_this_tourney > 0