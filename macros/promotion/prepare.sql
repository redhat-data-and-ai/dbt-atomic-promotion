{% macro prepare_build_schemas(schemas=none) %}
  {#-
    Clone each production schema to build_<schema>_<version>.
    Creates an empty build schema when production does not exist yet.
    Run this once per version. Running it again replaces that version's build schemas.
  -#}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {% set version = get_deployment_version() %}
  {% set database = promotion_database() %}
  {% set selected = promotion_schemas(schemas) %}
  {% if selected | length == 0 %}
    {{ exceptions.raise_compiler_error("No schemas to prepare. Set a schema on models, seeds, or snapshots, or pass schemas.") }}
  {% endif %}

  {% set version_upper = version | upper %}
  {% for schema in selected %}
    {% set build_schema = 'BUILD_' ~ schema ~ '_' ~ version_upper %}
    {% if build_schema | length > 255 %}
      {{ exceptions.raise_compiler_error("Build schema '" ~ build_schema ~ "' exceeds 255 characters.") }}
    {% endif %}
  {% endfor %}

  {% set existing = promotion_existing_schemas(database, selected) %}
  {{ log("", info=true) }}
  {{ log("Preparing build schemas", info=true) }}
  {{ log("  Version: " ~ version_upper, info=true) }}
  {% for schema in selected %}
    {% set build_schema = 'BUILD_' ~ schema ~ '_' ~ version_upper %}
    {% if schema in existing %}
      {{ log("  Clone " ~ schema ~ " -> " ~ build_schema, info=true) }}
    {% else %}
      {{ log("  Create " ~ build_schema ~ " (no production schema yet)", info=true) }}
    {% endif %}
  {% endfor %}

  {% set clone_sql %}
    {% for schema in selected %}
      {% set build_schema = 'BUILD_' ~ schema ~ '_' ~ version_upper %}
      CREATE OR REPLACE SCHEMA {{ database }}.{{ build_schema }}
      {%- if schema in existing %} CLONE {{ database }}.{{ schema }}{% endif %}
      {%- if not loop.last %};{% endif %}
    {% endfor %}
  {% endset %}
  {% do run_query(clone_sql) %}

  {{ log("", info=true) }}
  {{ log("Build schemas are ready for " ~ version_upper ~ ".", info=true) }}
  {{ log("Next: dbt build with the same deployment_version, then promote_all.", info=true) }}
  {{ log("Running prepare again for this version replaces the build schemas.", info=true) }}
  {{ log("", info=true) }}
{% endmacro %}
