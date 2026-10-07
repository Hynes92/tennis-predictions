-- One row per tennis-data.co.uk match (ATP + WTA main tour) with typed odds and
-- margin-free implied probabilities. Benchmarking only: never a model input.

with unioned as (
    {{ dbt_utils.union_relations(relations=[
        source('tennis_data', 'tennis_data_atp_matches'),
        source('tennis_data', 'tennis_data_wta_matches')
    ]) }}
),

-- A re-downloaded file (e.g. the current season) is appended again: keep only the
-- newest load of each file.
latest_load as (
    select
        *,
        case when _source_file like '%w/%' then 'wta' else 'atp' end as tour
    from unioned
    qualify _loaded_at = max(_loaded_at) over (partition by _source_file)
),

typed as (
    select
        tour,
        safe_cast(Date as date)                              as match_date,
        extract(year from safe_cast(Date as date))           as season,
        trim(Location)                                       as location,
        trim(Tournament)                                     as tournament,
        coalesce(Series, Tier)                               as tournament_tier,
        Court                                                as court,
        Surface                                              as surface,
        Round                                                as round,
        safe_cast(Best_of as int64)                          as best_of,
        trim(Winner)                                         as winner_name,
        trim(Loser)                                          as loser_name,
        safe_cast(WRank as int64)                            as winner_rank,
        safe_cast(LRank as int64)                            as loser_rank,
        safe_cast(Wsets as int64)                            as winner_sets,
        safe_cast(Lsets as int64)                            as loser_sets,
        Comment                                              as result_comment,
        coalesce(Comment = 'Completed', false)               as is_completed,

        -- decimal odds; anything <= 1.0 is a data error
        {% for book in ['PS', 'BFE', 'Avg', 'Max', 'B365'] %}
        if(safe_cast({{ book }}W as float64) > 1, safe_cast({{ book }}W as float64), null) as {{ book | lower }}_winner_odds,
        if(safe_cast({{ book }}L as float64) > 1, safe_cast({{ book }}L as float64), null) as {{ book | lower }}_loser_odds,
        {% endfor %}

        _source_file,
        _source_row_number,
        _loaded_at
    from latest_load
),

with_probs as (
    select
        *,
        -- margin removed by normalising the two implied probabilities to sum to 1
        {% for book in ['ps', 'bfe', 'avg'] %}
        safe_divide(1 / {{ book }}_winner_odds,
                    1 / {{ book }}_winner_odds + 1 / {{ book }}_loser_odds) as {{ book }}_prob_winner,
        {% endfor %}
    from typed
)

select
    {{ dbt_utils.generate_surrogate_key(['tour', 'match_date', 'winner_name', 'loser_name']) }}
        as tdata_match_key,
    *,
    coalesce(ps_prob_winner, bfe_prob_winner, avg_prob_winner) as benchmark_prob_winner,
    case
        when ps_prob_winner  is not null then 'pinnacle'
        when bfe_prob_winner is not null then 'betfair_exchange'
        when avg_prob_winner is not null then 'bookmaker_average'
    end                                                        as benchmark_source
from with_probs
where match_date is not null