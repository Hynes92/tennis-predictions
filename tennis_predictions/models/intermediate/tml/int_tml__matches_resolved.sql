-- stg_tml__matches with every winner_id / loser_id populated and sanity-checked.
--
-- TML data issues handled here, in order:
--   1. Wrong IDs: a row carries another player's ID. Replaced when BOTH the ID's main name
--      isn't this row's name AND this name has a different main ID.        -> 'corrected'
--   2. Duplicate IDs: a player has small leftover IDs used only with their own name (e.g. old
--      numeric IDs). An ID with <= 5 matches is merged into the name's main ID when that main
--      ID has >= 20 matches.                                                 -> 'alias_merged'
--   3. Missing IDs: filled by unambiguous name match within the tour         -> 'name_match'
--      or given a stable temporary ID until TML provides one                 -> 'temporary'

{% set alias_max_matches = 5 %}
{% set main_min_matches = 20 %}

with source_matches as (

    select
        *,
        {{ normalize_player_name('winner_name') }} as winner_name_key,
        {{ normalize_player_name('loser_name') }}  as loser_name_key
    from {{ ref('stg_tml__matches') }}

),

-- Every (tour, id, name) pairing exactly as TML provides it
raw_pairs as (

    select tour, winner_id as player_id, winner_name_key as name_key
    from source_matches
    where winner_id is not null and winner_name_key is not null

    union all

    select tour, loser_id, loser_name_key
    from source_matches
    where loser_id is not null and loser_name_key is not null

),

pair_counts as (

    select tour, player_id, name_key, count(*) as n
    from raw_pairs
    group by tour, player_id, name_key

),

id_totals as (

    select tour, player_id, sum(n) as total_matches
    from pair_counts
    group by tour, player_id

),

-- The name each ID appears with most often
id_main_name as (

    select tour, player_id, name_key as main_name_key
    from pair_counts
    qualify row_number() over (partition by tour, player_id order by n desc, name_key) = 1

),

-- The ID each name appears with most often
name_main_id as (

    select tour, name_key, player_id as main_player_id
    from pair_counts
    qualify row_number() over (partition by tour, name_key order by n desc, player_id) = 1

),

-- Step 1: replace an ID only when the ID and the name disagree in both directions
corrected as (

    select
        sm.* except (winner_id, loser_id),

        if(sm.winner_id is not null
           and sm.winner_name_key != wim.main_name_key
           and wnm.main_player_id is not null
           and wnm.main_player_id != sm.winner_id,
           wnm.main_player_id, sm.winner_id) as winner_id,

        if(sm.loser_id is not null
           and sm.loser_name_key != lim.main_name_key
           and lnm.main_player_id is not null
           and lnm.main_player_id != sm.loser_id,
           lnm.main_player_id, sm.loser_id) as loser_id,

        coalesce(sm.winner_id is not null
                 and sm.winner_name_key != wim.main_name_key
                 and wnm.main_player_id is not null
                 and wnm.main_player_id != sm.winner_id, false) as winner_id_corrected,

        coalesce(sm.loser_id is not null
                 and sm.loser_name_key != lim.main_name_key
                 and lnm.main_player_id is not null
                 and lnm.main_player_id != sm.loser_id, false) as loser_id_corrected,

        coalesce(sm.winner_id = sm.loser_id, false) as had_duplicate_player_id

    from source_matches as sm
    left join id_main_name as wim on wim.tour = sm.tour and wim.player_id = sm.winner_id
    left join id_main_name as lim on lim.tour = sm.tour and lim.player_id = sm.loser_id
    left join name_main_id as wnm on wnm.tour = sm.tour and wnm.name_key = sm.winner_name_key
    left join name_main_id as lnm on lnm.tour = sm.tour and lnm.name_key = sm.loser_name_key

),

-- Step 2: small leftover IDs that belong to the same name as a well-established main ID
alias_map as (

    select
        pc.tour,
        pc.player_id         as alias_id,
        nm.main_player_id
    from pair_counts as pc
    inner join id_main_name as im
        on im.tour = pc.tour and im.player_id = pc.player_id
       and im.main_name_key = pc.name_key              -- the alias only belongs to this name
    inner join name_main_id as nm
        on nm.tour = pc.tour and nm.name_key = pc.name_key
    inner join id_totals as alias_total
        on alias_total.tour = pc.tour and alias_total.player_id = pc.player_id
    inner join id_totals as main_total
        on main_total.tour = nm.tour and main_total.player_id = nm.main_player_id
    where pc.player_id != nm.main_player_id
      and alias_total.total_matches <= {{ alias_max_matches }}
      and main_total.total_matches >= {{ main_min_matches }}

),

merged as (

    select
        c.* except (winner_id, loser_id),
        coalesce(wa.main_player_id, c.winner_id) as winner_id,
        coalesce(la.main_player_id, c.loser_id)  as loser_id,
        wa.main_player_id is not null            as winner_id_merged,
        la.main_player_id is not null            as loser_id_merged
    from corrected as c
    left join alias_map as wa on wa.tour = c.tour and wa.alias_id = c.winner_id
    left join alias_map as la on la.tour = c.tour and la.alias_id = c.loser_id

),

-- Step 3: name -> ID lookup from the cleaned matches, for filling missing IDs
name_id_pairs as (

    select tour, winner_name_key as name_key, winner_id as player_id
    from merged
    where winner_id is not null and winner_name_key is not null

    union all

    select tour, loser_name_key, loser_id
    from merged
    where loser_id is not null and loser_name_key is not null

),

-- Only names that map to exactly one ID: never guess between two players with the same name
unambiguous_names as (

    select tour, name_key, any_value(player_id) as matched_player_id
    from name_id_pairs
    group by tour, name_key
    having count(distinct player_id) = 1

),

resolved as (

    select
        m.* except (winner_id, loser_id,
                    winner_id_corrected, loser_id_corrected,
                    winner_id_merged, loser_id_merged),

        coalesce(
            m.winner_id,
            w.matched_player_id,
            concat('tmp_', lower(m.tour), '_', replace(m.winner_name_key, ' ', '_'))
        ) as winner_id,
        case
            when m.winner_id_corrected           then 'corrected'
            when m.winner_id_merged              then 'alias_merged'
            when m.winner_id is not null         then 'tml'
            when w.matched_player_id is not null then 'name_match'
            else 'temporary'
        end as winner_id_source,

        coalesce(
            m.loser_id,
            l.matched_player_id,
            concat('tmp_', lower(m.tour), '_', replace(m.loser_name_key, ' ', '_'))
        ) as loser_id,
        case
            when m.loser_id_corrected            then 'corrected'
            when m.loser_id_merged               then 'alias_merged'
            when m.loser_id is not null          then 'tml'
            when l.matched_player_id is not null then 'name_match'
            else 'temporary'
        end as loser_id_source

    from merged as m
    left join unambiguous_names as w
        on m.winner_id is null
        and w.tour = m.tour
        and w.name_key = m.winner_name_key
    left join unambiguous_names as l
        on m.loser_id is null
        and l.tour = m.tour
        and l.name_key = m.loser_name_key

)

select * from resolved