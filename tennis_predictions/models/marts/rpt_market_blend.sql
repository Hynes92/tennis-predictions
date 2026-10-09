-- Does the model add information the market lacks? Blend market and model in log-odds:
--   blend = (1 - w) * logit(market) + w * logit(model)
-- Pick w on 'valid' (2024), read the result for that w on 'test' (2025+).
-- diff_vs_market < 0 with ci95_high < 0 on test = the model carries information the market misses.

with base as (
    select
        split,
        a_won,
        ln(greatest(least(market_prob_a, 1 - 1e-6), 1e-6) / (1 - greatest(least(market_prob_a, 1 - 1e-6), 1e-6))) as logit_market,
        ln(greatest(least(model_prob_a,  1 - 1e-6), 1e-6) / (1 - greatest(least(model_prob_a,  1 - 1e-6), 1e-6))) as logit_model,
        market_log_loss
    from {{ ref('fct_market_benchmark') }}
),

weights as (
    select w from unnest(generate_array(0.0, 1.0, 0.05)) as w
),

blended as (
    select
        b.split,
        w.w,
        b.market_log_loss,
        1 / (1 + exp(-((1 - w.w) * b.logit_market + w.w * b.logit_model))) as p_blend,
        b.a_won
    from base as b
    cross join weights as w
),

scored as (
    select
        *,
        -ln(if(a_won, greatest(least(p_blend, 1 - 1e-6), 1e-6),
                      1 - greatest(least(p_blend, 1 - 1e-6), 1e-6))) as blend_log_loss
    from blended
)

select
    split,
    round(w, 2)                                                    as model_weight,
    count(*)                                                       as n_matches,
    round(avg(blend_log_loss), 5)                                  as blend_log_loss,
    round(avg(market_log_loss), 5)                                 as market_log_loss,
    round(avg(blend_log_loss - market_log_loss), 5)                as diff_vs_market,
    round(avg(blend_log_loss - market_log_loss)
          - 1.96 * stddev(blend_log_loss - market_log_loss) / sqrt(count(*)), 5) as ci95_low,
    round(avg(blend_log_loss - market_log_loss)
          + 1.96 * stddev(blend_log_loss - market_log_loss) / sqrt(count(*)), 5) as ci95_high
from scored
group by split, w
order by split, w