{% macro norm_name(col) -%}
    trim(regexp_replace(regexp_replace(
        lower(regexp_replace(normalize({{ col }}, NFD), r'\p{M}', '')),
        r'[^a-z]+', ' '), r'\s+', ' '))
{%- endmacro %}