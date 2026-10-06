-- The A/B orientation must be unrelated to the result: player A should win close to 50%
-- of matches. A strong skew means the orientation leaks the label.
select avg(a_won) as a_win_rate, count(*) as matches
from {{ ref('fct_match_features') }}
having avg(a_won) not between 0.49 and 0.51