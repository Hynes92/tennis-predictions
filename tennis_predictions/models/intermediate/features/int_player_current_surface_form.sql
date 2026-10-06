-- Surface-specific form AS OF TODAY, one row per player x form_variant x surface.
-- Mirrors the surface_* features in int_player_form. Players with no matches on a surface
-- have no row; fct_upcoming_match_features treats that as 0 matches / NULL win rate.

with matches as (

    select * from {{ ref('int_player_match_stats') }}

),

latest_match as (

    select player_id, tourney_day
    from matches
    qualify row_number() over (partition by player_id order by match_sequence_key desc) = 1

),

variants as (

    select player_id, 'fresh' as form_variant, unix_date(current_date()) as window_end_day
    from latest_match
    union all
    select player_id, 'continuing', tourney_day
    from latest_match

)

select
    v.player_id,
    v.form_variant,
    m.surface,
    countif(m.tourney_day between v.window_end_day - 364 and v.window_end_day - 1)  as surface_matches_last_52w,
    avg(if(m.tourney_day between v.window_end_day - 364 and v.window_end_day - 1, m.won, null))
                                                                                     as surface_win_rate_last_52w,
    countif(m.tourney_day between v.window_end_day - 728 and v.window_end_day - 1)  as surface_matches_last_104w
from variants as v
inner join matches as m using (player_id)
where m.surface is not null
group by v.player_id, v.form_variant, m.surface