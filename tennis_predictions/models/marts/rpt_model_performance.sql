-- Live performance summary: settled predictions only, overall and by data tier.
-- Compares the model with the market and Elo on matches none of them had seen,
-- and reports the paper-trading results of the value bets.

with settled as (

    select * from {{ ref('fct_prediction_results') }}
    where status = 'settled'

),

by_segment as (

    select 'overall' as segment, * from settled
    union all
    select concat('tier: ', data_tier), * from settled
    union all
    select concat('tour: ', tour), * from settled

)

select
    segment,
    count(*)                                            as settled_matches,
    round(avg(model_log_loss), 4)                       as model_log_loss,
    round(avg(if(market_prob_a is not null, market_log_loss, null)), 4) as market_log_loss,
    round(avg(if(elo_prob_a is not null, elo_log_loss, null)), 4)       as elo_log_loss,
    round(avg(model_correct), 3)                        as model_accuracy,
    round(avg(market_correct), 3)                       as market_accuracy,
    sum(stake)                                          as bets,
    sum(bet_won)                                        as bets_won,
    round(sum(bet_profit), 2)                           as profit_units,
    round(safe_divide(sum(bet_profit), sum(stake)), 3)  as roi
from by_segment
group by segment
order by segment = 'overall' desc, segment