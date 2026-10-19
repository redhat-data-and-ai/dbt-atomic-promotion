{% macro cleanup_build_schemas(num_to_keep=none, dry_run=false) %}
  {#- Drop BUILD_ schemas from promoted versions outside the retention window. -#}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {% set retention = (num_to_keep if num_to_keep is not none else var('cleanup_build_schemas_to_keep', 5)) | int %}
  {% set is_dry_run = dry_run == true or (dry_run is string and dry_run | lower in ['true', '1', 'yes']) %}
  {% if retention < 1 %}
    {{ exceptions.raise_compiler_error("num_to_keep must be at least 1.") }}
  {% endif %}

  {% do ensure_logging_infrastructure() %}
  {% set database = promotion_database() %}
  {% set log_schema = promotion_audit_schema() %}

  {{ log("", info=true) }}
  {{ log("Build schema cleanup", info=true) }}
  {{ log("  Keep the newest " ~ retention ~ " promoted version(s)", info=true) }}
  {% if is_dry_run %}
    {{ log("  Dry run only", info=true) }}
  {% endif %}

  {% set find_sql %}
    WITH ranked_versions AS (
      SELECT
        version,
        DENSE_RANK() OVER (ORDER BY MAX(deployment_timestamp) DESC) AS build_rank
      FROM {{ database }}.{{ log_schema }}.deployment_log
      WHERE operation_type = 'PROMOTE'
        AND status = 'SUCCESS'
        AND REGEXP_LIKE(from_schema, '^BUILD_')
      GROUP BY version
    ),
    logged_schemas AS (
      SELECT DISTINCT from_schema AS build_schema, version
      FROM {{ database }}.{{ log_schema }}.deployment_log
      WHERE operation_type = 'PROMOTE'
        AND status = 'SUCCESS'
        AND REGEXP_LIKE(from_schema, '^BUILD_')
    ),
    existing_schemas AS (
      SELECT schema_name
      FROM {{ database }}.information_schema.schemata
      WHERE REGEXP_LIKE(schema_name, '^BUILD_')
    )
    SELECT s.build_schema, s.version, v.build_rank
    FROM logged_schemas s
    INNER JOIN ranked_versions v ON s.version = v.version
    INNER JOIN existing_schemas e ON s.build_schema = e.schema_name
    WHERE v.build_rank > {{ retention }}
    ORDER BY v.build_rank, s.build_schema
  {% endset %}
  {% set result = run_query(find_sql) %}

  {% if result.rows | length == 0 %}
    {{ log("No build schemas to drop.", info=true) }}
    {{ return('') }}
  {% endif %}

  {% set drop_names = [] %}
  {% for row in result.rows %}
    {% set build_schema = promotion_col(row, 'build_schema') %}
    {% do promotion_assert_identifier(build_schema, 'build schema') %}
    {% if not (build_schema | upper).startswith('BUILD_') %}
      {{ exceptions.raise_compiler_error("Refusing to drop '" ~ build_schema ~ "' because it is not a build schema.") }}
    {% endif %}
    {% do drop_names.append(build_schema | upper) %}
    {{ log("  " ~ (build_schema | upper) ~ " (promoted version rank " ~ promotion_col(row, 'build_rank') ~ ")", info=true) }}
  {% endfor %}

  {% if not is_dry_run %}
    {% do promotion_drop_schemas(database, drop_names) %}
    {{ log("Dropped " ~ (drop_names | length) ~ " build schema(s).", info=true) }}
  {% else %}
    {{ log("Dry run: no schemas were dropped.", info=true) }}
  {% endif %}
  {{ log("", info=true) }}
{% endmacro %}
