-- Matchup features AS OF TODAY, for scoring upcoming matches. Same definitions as
-- int_player_matchup_form (104-week window, same shrinkage), over every match played so far.
-- Players with no rows here have no history: fill with 0 when joining, as training does.

with history as (

    select * from {{ ref('int_player_match_history') }}
    where tourney_date >= date_sub(current_date(), interval 104 week)

)

select
    player_id,
    {% for kind in ['left', 'big_server', 'top50'] %}
    countif(opp_is_{{ kind }})                                              as vs_{{ kind }}_matches_104w,
    sum(if(opp_is_{{ kind }}, over_expected, 0))
        / (countif(opp_is_{{ kind }}) + 5)                                  as vs_{{ kind }}_over_expected_104w,
    {% endfor %}
from history
group by player_id