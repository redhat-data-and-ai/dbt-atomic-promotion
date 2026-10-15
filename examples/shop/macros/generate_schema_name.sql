{% macro generate_schema_name(custom_schema_name, node) %}
    {{ return(atomic_promotion.promotion_schema_name(custom_schema_name, node)) }}
{% endmacro %}
