{#
  Standardise a player name for matching across sources:
  "Kopřiva", "KOPRIVA " and "Ko-priva" all become comparable.
    - decompose accented characters and strip the accent marks
    - lowercase
    - any non-letter (hyphen, apostrophe, dot) becomes a space
    - collapse repeated spaces and trim
#}
{% macro normalize_player_name(column) -%}
    trim(regexp_replace(
        regexp_replace(
            lower(regexp_replace(normalize({{ column }}, NFD), r'\p{M}', '')),
            r'[^a-z]', ' '
        ),
        r'\s+', ' '
    ))
{%- endmacro %}