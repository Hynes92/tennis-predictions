-- One row per Betfair MATCH_ODDS market per snapshot, typed and flagged.
-- Keeps every snapshot: the history is used later for closing-price benchmarks.

with source as (

    select * from {{ source('betfair', 'betfair_markets') }}

)

select
    market_id,
    _snapshot_id                                    as snapshot_id,
    _snapshot_at                                    as snapshot_at,
    market_start_time,
    event_id,
    event_name,
    competition_id,
    competition_name,
    event_country_code,
    runner_count,
    book_status                                     as market_status,
    book_inplay                                     as is_inplay,
    coalesce(book_total_matched, catalogue_total_matched) as total_matched,

    -- Doubles events are named "A/B v C/D"
    regexp_contains(event_name, r'/')               as is_doubles,

    -- Exhibitions: not competitive, excluded from predictions
    regexp_contains(lower(competition_name),
        r'laver cup|exhibition|hopman|ultimate tennis showdown|\buts\b') as is_exhibition,

    case
        when regexp_contains(lower(competition_name), r'challenger') then 'challenger'
        when regexp_contains(lower(competition_name), r'^itf')       then 'itf'
        else 'main_tour'
    end                                             as competition_level,

    -- Tour hint from the competition name. NULL when the name doesn't say
    -- (e.g. "US Open 2026"); the player mapping resolves those.
    case
        when regexp_contains(lower(competition_name), r'\bwta\b|^itf w|women') then 'WTA'
        when regexp_contains(lower(competition_name), r'\batp\b|challenger|^itf m|\bmen') then 'ATP'
    end                                             as tour_hint

from source