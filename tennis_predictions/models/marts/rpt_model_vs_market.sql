-- Model vs market log loss, by period / tour / benchmark source. diff = model - market
-- (negative = model better). Paired on the same matches, with a 95% confidence interval.

with base as (
    select
        *,
        model_log_loss - market_log_loss as diff_vs_market
    from {{ ref('fct_market_benchmark') }}
),

grouped as (
    select
        split,
        tour,
        benchmark_source,
        count(*)                          as n_matches,
        avg(model_log_loss)               as model_log_loss,
        avg(logreg_log_loss)              as logreg_log_loss,
        avg(elo_log_loss)                 as elo_log_loss,
        avg(market_log_loss)              as market_log_loss,
        avg(diff_vs_market)               as diff_vs_market,
        stddev(diff_vs_market) / sqrt(count(*)) as diff_std_error
    from base
    group by grouping sets (
        (split),
        (split, tour),
        (split, benchmark_source)
    )
)

select
    split,
    coalesce(tour, 'all')              as tour,
    coalesce(benchmark_source, 'all')  as benchmark_source,
    n_matches,
    round(model_log_loss, 4)           as model_log_loss,
    round(logreg_log_loss, 4)          as logreg_log_loss,
    round(elo_log_loss, 4)             as elo_log_loss,
    round(market_log_loss, 4)          as market_log_loss,
    round(diff_vs_market, 4)           as model_minus_market,
    round(diff_vs_market - 1.96 * diff_std_error, 4) as ci95_low,
    round(diff_vs_market + 1.96 * diff_std_error, 4) as ci95_high
from grouped
order by split, tour, benchmark_source