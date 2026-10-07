-- Links each tennis-data.co.uk match to its TennisMyLife match_key (same tour, date window,
-- winner and loser both matching on surname + first initial). Benchmarking only.

with tdata as (
    select
        tdata_match_key,
        tour,
        match_date,
        -- "Zhang Zh." -> surname "Zhang", initials "Zh.";  "Del Potro J.M." -> "Del Potro", "J.M."
        coalesce(regexp_extract(winner_name, r'^(.*?)\s+(?:[^\s.]+\.\s*)+$'), winner_name) as w_surname_raw,
        regexp_extract(winner_name, r'\s([^\s.]+)\.(?:[^\s.]+\.|\s)*$')                    as w_initial_raw,
        coalesce(regexp_extract(loser_name,  r'^(.*?)\s+(?:[^\s.]+\.\s*)+$'), loser_name)  as l_surname_raw,
        regexp_extract(loser_name,  r'\s([^\s.]+)\.(?:[^\s.]+\.|\s)*$')                    as l_initial_raw
    from {{ ref('stg_tennis_data__matches') }}
),

name_parts as (
    select
        tdata_match_key,
        tour,
        match_date,
        {{ norm_name('w_surname_raw') }}                       as w_surname,
        nullif(replace({{ norm_name('w_initial_raw') }}, ' ', ''), '') as w_initial,
        {{ norm_name('l_surname_raw') }}                       as l_surname,
        nullif(replace({{ norm_name('l_initial_raw') }}, ' ', ''), '') as l_initial
    from tdata
),

tml as (
    select
        match_key,
        lower(tour) as tour,
        event_date,
        {{ norm_name('winner_name') }} as w_full,
        {{ norm_name('loser_name') }}  as l_full
    from {{ ref('int_tml__matches_resolved') }}
    where source_dataset in ('atp_tour', 'wta_tour')    -- tennis-data covers main tour only
      and event_date >= '2019-11-01'
),

candidates as (
    select
        p.tdata_match_key,
        t.match_key,
        date_diff(p.match_date, t.event_date, day) as days_after_start,
        (ends_with(t.w_full, ' ' || p.w_surname) or t.w_full = p.w_surname)
            and (p.w_initial is null or starts_with(t.w_full, p.w_initial)) as w_strong,
        (ends_with(t.l_full, ' ' || p.l_surname) or t.l_full = p.l_surname)
            and (p.l_initial is null or starts_with(t.l_full, p.l_initial)) as l_strong
    from name_parts as p
    inner join tml as t
        on t.tour = p.tour
        and p.match_date between date_sub(t.event_date, interval 3 day)
                             and date_add(t.event_date, interval 21 day)
    -- at minimum, the first surname word of both players appears in the TML names
    where split(p.w_surname, ' ')[safe_offset(0)] in unnest(split(t.w_full, ' '))
      and split(p.l_surname, ' ')[safe_offset(0)] in unnest(split(t.l_full, ' '))
),

scored as (
    select
        *,
        cast(w_strong as int64) + cast(l_strong as int64) as name_score
    from candidates
),

-- best candidate per tennis-data match: strongest names, then the nearest tournament
-- start on or before the match date
best as (
    select
        *,
        count(*) over (partition by tdata_match_key, name_score, days_after_start) as n_tied
    from scored
    qualify row_number() over (
        partition by tdata_match_key
        order by name_score desc, days_after_start < 0, days_after_start
    ) = 1
),

-- a TML match can be claimed by only one tennis-data row
claimed as (
    select *
    from best
    qualify row_number() over (
        partition by match_key
        order by name_score desc, abs(days_after_start)
    ) = 1
)

select
    s.*,
    c.match_key,
    c.name_score,
    c.days_after_start,
    case
        when c.match_key is null then 'unmatched'
        when c.n_tied > 1        then 'ambiguous'
        when c.name_score = 2    then 'strong'
        else 'weak'
    end as match_status
from {{ ref('stg_tennis_data__matches') }} as s
left join claimed as c
    on c.tdata_match_key = s.tdata_match_key