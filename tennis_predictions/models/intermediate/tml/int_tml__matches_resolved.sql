-- stg_tml__matches with every winner_id / loser_id populated and sanity-checked.
--
-- Two TML data issues are handled here:
--   1. Missing IDs: some current-season matches arrive without player IDs.
--   2. Duplicated IDs: occasionally both players carry the same ID (one side copied
--      from the other). The ID is kept for the player whose name matches the ID's
--      main name, and blanked for the other so it can be re-resolved.
--
-- Blank IDs are filled by unambiguous name match within the same tour. Players never
-- seen with an ID get a stable temporary ID so their matches still link together; the
-- next nightly build swaps in the real ID once TML provides one.

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

-- The name each ID appears with most often: its "true" owner
id_main_name as (

    select tour, player_id, name_key as main_name_key
    from raw_pairs
    group by tour, player_id, name_key
    qualify row_number() over (
        partition by tour, player_id
        order by count(*) desc, name_key
    ) = 1

),

-- Fix duplicated IDs: blank the side whose name doesn't own the ID
matches as (

    select
        sm.* except (winner_id, loser_id),

        if(sm.winner_id = sm.loser_id and sm.winner_name_key != wm.main_name_key,
           null, sm.winner_id) as winner_id,
        if(sm.winner_id = sm.loser_id and sm.loser_name_key != lm.main_name_key,
           null, sm.loser_id) as loser_id,

        coalesce(sm.winner_id = sm.loser_id, false) as had_duplicate_player_id

    from source_matches as sm
    left join id_main_name as wm
        on wm.tour = sm.tour and wm.player_id = sm.winner_id
    left join id_main_name as lm
        on lm.tour = sm.tour and lm.player_id = sm.loser_id

),

-- Name -> ID lookup built from the cleaned matches
name_id_pairs as (

    select tour, winner_name_key as name_key, winner_id as player_id
    from matches
    where winner_id is not null and winner_name_key is not null

    union all

    select tour, loser_name_key, loser_id
    from matches
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
        m.* except (winner_id, loser_id),

        coalesce(
            m.winner_id,
            w.matched_player_id,
            concat('tmp_', lower(m.tour), '_', replace(m.winner_name_key, ' ', '_'))
        ) as winner_id,
        case
            when m.winner_id is not null then 'tml'
            when w.matched_player_id is not null then 'name_match'
            else 'temporary'
        end as winner_id_source,

        coalesce(
            m.loser_id,
            l.matched_player_id,
            concat('tmp_', lower(m.tour), '_', replace(m.loser_name_key, ' ', '_'))
        ) as loser_id,
        case
            when m.loser_id is not null then 'tml'
            when l.matched_player_id is not null then 'name_match'
            else 'temporary'
        end as loser_id_source

    from matches as m
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