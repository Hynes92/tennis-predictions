-- The paper-trading ledger: every prediction settled against the real result.
-- One row per Betfair market, using the LAST prediction made before the match started.
--
-- Matching: predictions and TML results share no ID, so a result is matched on the two
-- player IDs (either order) within a few days of the market start time.
-- Settlement (Betfair tennis rules): walkover / default / abandoned = void (stake returned);
-- a retirement after the start stands, with the player progressing as the winner.
-- Paper bets: flat 1-unit stake on every flagged value bet at the back price available at
-- prediction time, with commission deducted from winnings.

{% set commission = 0.05 %}
{% set settle_after_days = 4 %}

with predictions as (

    select *
    from {{ source('scoring', 'predictions') }}
    where predicted_at < market_start_time
    qualify row_number() over (partition by market_id order by predicted_at desc) = 1

),

results as (

    select
        match_key,
        winner_id,
        loser_id,
        event_date,
        -- tournament's first date, for sources that only give the tournament start date
        min(event_date) over (partition by tour, tourney_id) as tourney_date,
        score,
        is_walkover or is_default
            or regexp_contains(upper(score), r'WEA|ABD|ABN|UNFINISHED|UNP') as is_void_result,
        is_retirement
    from {{ ref('int_tml__matches_resolved') }}
    where event_date >= date '2026-08-15'

),

matched_results as (

    select
        p.market_id,
        r.match_key   as tml_match_key,
        r.winner_id,
        r.score,
        r.is_void_result,
        r.is_retirement
    from predictions as p
    inner join results as r
        on ((r.winner_id = p.player_a_id and r.loser_id = p.player_b_id)
         or (r.winner_id = p.player_b_id and r.loser_id = p.player_a_id))
       and (abs(date_diff(r.event_date, date(p.market_start_time), day)) <= 3
            or date_diff(date(p.market_start_time), r.tourney_date, day) between -3 and 16)
    qualify row_number() over (
        partition by p.market_id
        order by abs(date_diff(r.event_date, date(p.market_start_time), day))
    ) = 1

),

settled as (

    select
        p.*,
        m.tml_match_key,
        m.score,
        coalesce(m.is_retirement, false) as is_retirement,
        case
            when m.tml_match_key is null
             and p.market_start_time > timestamp_sub(current_timestamp(), interval {{ settle_after_days }} day)
                                                  then 'pending'
            when m.tml_match_key is null          then 'unsettled'
            when m.is_void_result                 then 'void'
            else 'settled'
        end as status,
        if(m.tml_match_key is not null and not m.is_void_result,
           if(m.winner_id = p.player_a_id, 1, 0), null) as a_won
    from predictions as p
    left join matched_results as m using (market_id)

),

scored as (

    select
        *,
        -- log loss for each forecaster (lower is better); probabilities clipped to avoid log(0)
        -(a_won * ln(greatest(least(model_prob_a, 1 - 1e-6), 1e-6))
          + (1 - a_won) * ln(greatest(least(1 - model_prob_a, 1 - 1e-6), 1e-6)))  as model_log_loss,
        -(a_won * ln(greatest(least(market_prob_a, 1 - 1e-6), 1e-6))
          + (1 - a_won) * ln(greatest(least(1 - market_prob_a, 1 - 1e-6), 1e-6))) as market_log_loss,
        -(a_won * ln(greatest(least(elo_prob_a, 1 - 1e-6), 1e-6))
          + (1 - a_won) * ln(greatest(least(1 - elo_prob_a, 1 - 1e-6), 1e-6)))    as elo_log_loss,
        if(a_won is null, null, if((model_prob_a >= 0.5) = (a_won = 1), 1, 0))     as model_correct,
        if(a_won is null or market_prob_a is null, null,
           if((market_prob_a >= 0.5) = (a_won = 1), 1, 0))                         as market_correct,

        -- paper bet
        if(is_value_bet and status in ('settled', 'void'), 1.0, 0.0)               as stake,
        case value_side when 'a' then a_back_price when 'b' then b_back_price end  as bet_price,
        case
            when not is_value_bet or status != 'settled' then null
            when (value_side = 'a' and a_won = 1) or (value_side = 'b' and a_won = 0) then 1
            else 0
        end                                                                         as bet_won
    from settled

)

select
    *,
    case
        when stake = 0 or status = 'void' then 0.0
        when bet_won = 1 then (bet_price - 1) * (1 - {{ commission }})
        else -1.0
    end as bet_profit
from scored