-- Betfair selection_id -> TML player_id, one row per Betfair singles player ever seen.
-- selection_id is permanent per player, so each mapping only has to be found once.
--
-- Match priority: manual override > exact name (same tour) > same name words in any order
-- (handles "Zhang Zhizhen" vs "Zhizhen Zhang"). Ties between TML players with the same name
-- go to the most recently active one, flagged is_ambiguous.

with betfair_players as (

    select
        r.selection_id,
        array_agg(r.runner_name order by r.snapshot_at desc limit 1)[offset(0)] as runner_name,
        array_agg(m.tour_hint ignore nulls order by r.snapshot_at desc limit 1)[safe_offset(0)] as tour_hint,
        max(r.snapshot_at) as last_seen_at
    from {{ ref('stg_betfair__runner_snapshots') }} as r
    inner join {{ ref('stg_betfair__market_snapshots') }} as m
        on m.market_id = r.market_id and m.snapshot_id = r.snapshot_id
    where not m.is_doubles
    group by r.selection_id

),

betfair_keyed as (

    select
        *,
        {{ normalize_player_name('runner_name') }} as name_key
    from betfair_players

),

tml_players as (

    select
        tour,
        player_id,
        name_key,
        max(tourney_date) as last_played,
        count(*)          as matches_played
    from (
        select tour, player_id, tourney_date,
               {{ normalize_player_name('player_name') }} as name_key
        from {{ ref('int_tml__player_matches') }}
    )
    group by tour, player_id, name_key

),

-- Same words in any order: "zhang zhizhen" and "zhizhen zhang" both become "zhang zhizhen"
token_keys as (

    select 'betfair' as side, cast(selection_id as string) as id, name_key,
           array_to_string(array(select w from unnest(split(name_key, ' ')) as w order by w), ' ') as token_key
    from betfair_keyed
    union all
    select 'tml', concat(tour, '|', player_id), name_key,
           array_to_string(array(select w from unnest(split(name_key, ' ')) as w order by w), ' ')
    from tml_players

),

exact_candidates as (

    select
        b.selection_id,
        t.player_id,
        t.tour,
        'exact_name' as match_method,
        count(*) over (partition by b.selection_id) > 1 as is_ambiguous,
        row_number() over (partition by b.selection_id
                           order by t.last_played desc, t.matches_played desc) as rn
    from betfair_keyed as b
    inner join tml_players as t
        on t.name_key = b.name_key
       and (b.tour_hint is null or t.tour = b.tour_hint)

),

token_candidates as (

    select
        b.selection_id,
        t.player_id,
        t.tour,
        'name_any_order' as match_method,
        count(*) over (partition by b.selection_id) > 1 as is_ambiguous,
        row_number() over (partition by b.selection_id
                           order by t.last_played desc, t.matches_played desc) as rn
    from betfair_keyed as b
    inner join token_keys as bk
        on bk.side = 'betfair' and bk.id = cast(b.selection_id as string)
    inner join token_keys as tk
        on tk.side = 'tml' and tk.token_key = bk.token_key
    inner join tml_players as t
        on concat(t.tour, '|', t.player_id) = tk.id
       and (b.tour_hint is null or t.tour = b.tour_hint)

),

-- Betfair truncates runner names at ~23 characters ("Alexander Ikenna Okonkw").
-- For long names, match TML names that START with the Betfair name.
prefix_candidates as (

    select
        b.selection_id,
        t.player_id,
        t.tour,
        'name_prefix' as match_method,
        count(*) over (partition by b.selection_id) > 1 as is_ambiguous,
        row_number() over (partition by b.selection_id
                           order by t.last_played desc, t.matches_played desc) as rn
    from betfair_keyed as b
    inner join tml_players as t
        on starts_with(t.name_key, b.name_key)
       and (b.tour_hint is null or t.tour = b.tour_hint)
    where char_length(b.runner_name) >= 22

),

overrides as (

    select selection_id, tml_player_id, note
    from {{ ref('betfair_player_overrides') }}

)

select
    b.selection_id,
    b.runner_name,
    b.name_key,
    b.tour_hint,
    b.last_seen_at,
    coalesce(o.tml_player_id, e.player_id, t.player_id, p.player_id)  as tml_player_id,
    coalesce(e.tour, t.tour, p.tour, b.tour_hint)                     as tour,
    case
        when o.tml_player_id is not null then 'override'
        when e.player_id is not null     then e.match_method
        when t.player_id is not null     then t.match_method
        when p.player_id is not null     then p.match_method
        else 'unmatched'
    end                                                                as match_method,
    coalesce(o.tml_player_id is null
             and coalesce(e.is_ambiguous, t.is_ambiguous, p.is_ambiguous), false)
                                                                       as is_ambiguous
from betfair_keyed as b
left join overrides as o using (selection_id)
left join exact_candidates  as e on e.selection_id = b.selection_id and e.rn = 1
left join token_candidates  as t on t.selection_id = b.selection_id and t.rn = 1
left join prefix_candidates as p on p.selection_id = b.selection_id and p.rn = 1