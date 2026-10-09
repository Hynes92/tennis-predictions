-- Out-of-sample model predictions (2024 validation, 2025+ test) next to bookmaker closing
-- odds for the same matches. Odds are only compared against here, never model inputs.

with backtest as (
    select * from {{ source('scoring', 'backtest_predictions') }}
),

odds as (
    select *
    from {{ ref('int_tennis_data__matched') }}
    where match_status in ('strong', 'weak')
),

joined as (
    select
        b.match_key,
        b.split,
        b.tourney_date,
        o.tour,
        o.season,
        o.tournament,
        o.tournament_tier,
        o.surface,
        o.round,
        o.is_completed,
        o.match_status,
        o.benchmark_source,
        b.data_tier,
        b.a_won,

        b.model_prob_a,
        b.logreg_prob_a,
        b.elo_prob_a,
        -- tennis-data odds are winner/loser: turn them into player A / player B
        if(b.a_won, o.benchmark_prob_winner, 1 - o.benchmark_prob_winner) as market_prob_a,
        {% for book in ['ps', 'bfe', 'avg', 'max'] %}
        if(b.a_won, o.{{ book }}_winner_odds, o.{{ book }}_loser_odds) as {{ book }}_odds_a,
        if(b.a_won, o.{{ book }}_loser_odds, o.{{ book }}_winner_odds) as {{ book }}_odds_b,
        {% endfor %}
    from backtest as b
    inner join odds as o
        on o.match_key = b.match_key
    where o.benchmark_prob_winner is not null
)

select
    *,
    -- per-match log loss (probabilities clipped away from 0 and 1)
    {% for m in ['model', 'logreg', 'elo', 'market'] %}
    -ln(if(a_won, greatest(least({{ m }}_prob_a, 1 - 1e-6), 1e-6),
                  1 - greatest(least({{ m }}_prob_a, 1 - 1e-6), 1e-6))) as {{ m }}_log_loss,
    {% endfor %}
from joined