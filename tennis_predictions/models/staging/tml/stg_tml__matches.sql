-- One row per TennisMyLife match across ATP tour, Challenger, ATP qualifying and WTA.
-- Staging only: union, dedupe, cast, rename, and a few flags read straight off the source.
-- No business logic (ratings, form, etc.) - that belongs in intermediate models.

with unioned as (

    -- union_relations lines columns up by name and fills NULLs where a table lacks a column,
    -- so older files with fewer columns can't break the union.
    {{ dbt_utils.union_relations(
        relations=[
            source('tml', 'tml_atp_matches'),
            source('tml', 'tml_challenger_matches'),
            source('tml', 'tml_atp_quali_matches'),
            source('tml', 'tml_wta_matches'),
        ],
        source_column_name='_bronze_table'
    ) }}

),

labelled as (

    select
        *,
        case
            when _bronze_table like '%tml_wta_matches%'        then 'wta_tour'
            when _bronze_table like '%tml_challenger_matches%' then 'atp_challenger'
            when _bronze_table like '%tml_atp_quali_matches%'  then 'atp_qualifying'
            else 'atp_tour'
        end as source_dataset
    from unioned

),

-- Bronze is append-only: the same match can arrive in both a yearly file and the
-- ongoing-tournaments file, and again after a correction. Keep the most recent load.
deduplicated as (

    select *
    from labelled
    where tourney_id is not null
    qualify row_number() over (
        partition by source_dataset, tourney_id, match_num
        order by _loaded_at desc, _source_row_number desc
    ) = 1

),

final as (

    select
        -- keys
        {{ dbt_utils.generate_surrogate_key(['source_dataset', 'tourney_id', 'match_num']) }} as match_key,
        source_dataset,
        if(source_dataset = 'wta_tour', 'WTA', 'ATP')                   as tour,
        case source_dataset
            when 'atp_challenger' then 'challenger'
            when 'atp_qualifying' then 'qualifying'
            else 'main_tour'
        end                                                             as competition_level,
        tourney_id,
        safe_cast(match_num as int64)                                   as match_num,

        -- tournament
        tourney_name,
        tourney_level                                                   as tourney_level_raw,
        lower(surface)                                                  as surface,
        case upper(indoor) when 'I' then true when 'O' then false end   as is_indoor,
        safe_cast(draw_size as int64)                                   as draw_size,
        safe.parse_date('%Y%m%d', tourney_date)                         as tourney_start_date,
        safe_cast(best_of as int64)                                     as best_of,

        -- round, with a sortable order so matches within a tournament can be sequenced
        -- (TML has no per-match date, only the tournament start date)
        round,
            case upper(trim(round))
                when 'Q1'            then 1
                when 'Q2'            then 2
                when 'Q3'            then 3
                when 'Q4'            then 4
                when 'R256'          then 9
                when 'R128'          then 10
                when 'R64'           then 11
                when 'R32'           then 12
                when 'R16'           then 13
                when 'RR'            then 14
                when 'QF'            then 15
                when 'QUARTERFINALS' then 15
                when 'SF'            then 16
                when 'BR'            then 17
                when '3RD/4TH'       then 17
                when 'F'             then 18
                when 'FS'            then 18
            end                                                         as round_order,

        -- result
        score,
        regexp_contains(upper(score), r'W/?O')                          as is_walkover,
        regexp_contains(upper(score), r'RET')                           as is_retirement,
        regexp_contains(upper(score), r'DEF')                           as is_default,
        safe_cast(minutes as int64)                                     as minutes,

        -- winner
        winner_id,
        winner_name,
        safe_cast(winner_seed as int64)                                 as winner_seed,
        winner_entry,
        winner_hand,
        safe_cast(winner_ht as int64)                                   as winner_height_cm,
        winner_ioc,
        safe_cast(winner_age as float64)                                as winner_age,
        safe_cast(winner_rank as int64)                                 as winner_rank,
        safe_cast(winner_rank_points as int64)                          as winner_rank_points,

        -- loser
        loser_id,
        loser_name,
        safe_cast(loser_seed as int64)                                  as loser_seed,
        loser_entry,
        loser_hand,
        safe_cast(loser_ht as int64)                                    as loser_height_cm,
        loser_ioc,
        safe_cast(loser_age as float64)                                 as loser_age,
        safe_cast(loser_rank as int64)                                  as loser_rank,
        safe_cast(loser_rank_points as int64)                           as loser_rank_points,

        -- winner serve stats
        safe_cast(w_ace as int64)                                       as w_aces,
        safe_cast(w_df as int64)                                        as w_double_faults,
        safe_cast(w_svpt as int64)                                      as w_serve_points,
        safe_cast(w_1stIn as int64)                                     as w_first_serves_in,
        safe_cast(w_1stWon as int64)                                    as w_first_serve_points_won,
        safe_cast(w_2ndWon as int64)                                    as w_second_serve_points_won,
        safe_cast(w_SvGms as int64)                                     as w_service_games,
        safe_cast(w_bpSaved as int64)                                   as w_break_points_saved,
        safe_cast(w_bpFaced as int64)                                   as w_break_points_faced,

        -- loser serve stats
        safe_cast(l_ace as int64)                                       as l_aces,
        safe_cast(l_df as int64)                                        as l_double_faults,
        safe_cast(l_svpt as int64)                                      as l_serve_points,
        safe_cast(l_1stIn as int64)                                     as l_first_serves_in,
        safe_cast(l_1stWon as int64)                                    as l_first_serve_points_won,
        safe_cast(l_2ndWon as int64)                                    as l_second_serve_points_won,
        safe_cast(l_SvGms as int64)                                     as l_service_games,
        safe_cast(l_bpSaved as int64)                                   as l_break_points_saved,
        safe_cast(l_bpFaced as int64)                                   as l_break_points_faced,

        safe_cast(w_svpt as int64) is not null
            and safe_cast(l_svpt as int64) is not null                  as has_serve_stats,

        -- lineage
        _bronze_table,
        _source_file,
        _loaded_at

    from deduplicated

)

select * from final