{# Copy this file to the root project's macros/generate_schema_name.sql.
   dbt ignores generate_schema_name when it is defined only inside a package. #}

{% macro generate_schema_name(custom_schema_name, node) %}
    {{ return(atomic_promotion.promotion_schema_name(custom_schema_name, node)) }}
{% endmacro %}
