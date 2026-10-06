{#
  The per-player features and A-minus-B differences used by BOTH fct_match_features (training)
  and fct_upcoming_match_features (scoring). One list = identical columns in both tables.
#}
{% macro match_side_features() %}
    {{ return([
        'elo_pre', 'surface_elo_pre', 'glicko_rating_pre', 'glicko_rd_pre',
        'matches_played_pre', 'surface_matches_played_pre', 'days_since_last_match',
        'rank', 'rank_points', 'age', 'height_cm', 'is_left_handed', 'is_qualifier', 'is_wildcard', 'seed',
        'matches_last_10', 'win_rate_last_10',
        'matches_last_52w', 'win_rate_last_52w',
        'surface_matches_last_52w', 'surface_win_rate_last_52w', 'surface_matches_last_104w',
        'stats_matches_last_52w',
        'first_serve_in_pct_52w', 'first_serve_won_pct_52w', 'second_serve_won_pct_52w',
        'serve_points_won_pct_52w', 'ace_rate_52w', 'double_fault_rate_52w',
        'break_points_saved_pct_52w', 'service_hold_pct_52w',
        'return_points_won_pct_52w', 'break_points_converted_pct_52w',
        'matches_last_4w', 'matches_this_tourney', 'minutes_this_tourney', 'sets_this_tourney',
    ]) }}
{% endmacro %}

{% macro match_diff_features() %}
    {{ return([
        'elo_pre', 'surface_elo_pre', 'glicko_rating_pre', 'age', 'height_cm',
        'win_rate_last_10', 'win_rate_last_52w', 'surface_win_rate_last_52w',
        'serve_points_won_pct_52w', 'return_points_won_pct_52w',
        'service_hold_pct_52w', 'break_points_converted_pct_52w',
        'matches_last_4w', 'minutes_this_tourney', 'sets_this_tourney',
    ]) }}
{% endmacro %}