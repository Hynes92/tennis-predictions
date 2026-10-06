-- One row per player (runner) per market per snapshot, with prices.

with source as (

    select * from {{ source('betfair', 'betfair_price_snapshots') }}

)

select
    market_id,
    _snapshot_id            as snapshot_id,
    _snapshot_at            as snapshot_at,
    selection_id,
    runner_name,
    sort_priority,
    runner_status,
    last_price_traded,
    runner_total_matched,
    back_price_1,
    back_size_1,
    lay_price_1,
    lay_size_1,

    -- Midpoint of best back and lay; falls back to whichever exists, then last traded
    case
        when back_price_1 is not null and lay_price_1 is not null then (back_price_1 + lay_price_1) / 2
        else coalesce(back_price_1, lay_price_1, last_price_traded)
    end                     as mid_price

from source