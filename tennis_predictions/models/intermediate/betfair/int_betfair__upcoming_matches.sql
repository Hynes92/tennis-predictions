-- Upcoming singles matches from the most recent Betfair snapshot: one row per market,
-- both players side by side, with the market-implied probability (benchmark only,
-- never a model feature).

with latest_snapshot as (

    select max(snapshot_at) as snapshot_at
    from {{ ref('stg_betfair__market_snapshots') }}

),

markets as (

    select m.*
    from {{ ref('stg_betfair__market_snapshots') }} as m
    inner join latest_snapshot as l using (snapshot_at)
    where m.market_start_time > m.snapshot_at
      and not m.is_doubles
      and not m.is_exhibition
      and not coalesce(m.is_inplay, false)
      and m.runner_count = 2
      and coalesce(m.market_status, 'OPEN') = 'OPEN'

),

runners as (

    select
        r.*,
        row_number() over (partition by r.market_id order by r.sort_priority, r.selection_id) as runner_slot
    from {{ ref('stg_betfair__runner_snapshots') }} as r
    inner join markets as m
        on m.market_id = r.market_id and m.snapshot_id = r.snapshot_id

),

paired as (

    select
        m.market_id,
        m.snapshot_id,
        m.snapshot_at,
        m.market_start_time,
        m.event_name,
        m.competition_id,
        m.competition_name,
        m.event_country_code,
        m.competition_level,
        m.tour_hint,
        m.total_matched,

        r1.selection_id   as runner_1_selection_id,
        r1.runner_name    as runner_1_name,
        r1.back_price_1   as runner_1_back_price,
        r1.lay_price_1    as runner_1_lay_price,
        r1.mid_price      as runner_1_mid_price,

        r2.selection_id   as runner_2_selection_id,
        r2.runner_name    as runner_2_name,
        r2.back_price_1   as runner_2_back_price,
        r2.lay_price_1    as runner_2_lay_price,
        r2.mid_price      as runner_2_mid_price

    from markets as m
    inner join runners as r1 on r1.market_id = m.market_id and r1.runner_slot = 1
    inner join runners as r2 on r2.market_id = m.market_id and r2.runner_slot = 2

)

select
    *,
    -- Market-implied probability that runner 1 wins, with the overround removed
    safe_divide(1 / runner_1_mid_price, 1 / runner_1_mid_price + 1 / runner_2_mid_price)
        as market_prob_runner_1
from paired