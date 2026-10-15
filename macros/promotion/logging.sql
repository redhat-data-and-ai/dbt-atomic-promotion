{% macro _is_verbose() %}
  {% set from_var = var('promotion_verbose', false) %}
  {% set from_env = env_var('PROMOTION_VERBOSE', 'false') | lower in ['true', '1', 'yes'] %}
  {{ return(from_var == true or (from_var | string | lower) in ['true', '1', 'yes'] or from_env) }}
{% endmacro %}


{% macro _log_verbose(message, prefix='      ') %}
  {% if _is_verbose() %}
    {{ log(prefix ~ message, info=true) }}
  {% endif %}
{% endmacro %}


{% macro _log_sql_verbose(sql_description, sql_text) %}
  {% if _is_verbose() %}
    {{ log("      [verbose] " ~ sql_description ~ ":", info=true) }}
    {% set display_sql = sql_text | trim %}
    {% if display_sql | length > 500 %}
      {% set display_sql = display_sql[:500] ~ "... (truncated)" %}
    {% endif %}
    {% for line in display_sql.split('\n') %}
      {{ log("        " ~ line, info=true) }}
    {% endfor %}
  {% endif %}
{% endmacro %}


{% macro _log_grants_detail(grants_result, schema_name) %}
  {% if _is_verbose() and grants_result is not none %}
    {{ log("      [verbose] Grants for " ~ schema_name ~ ":", info=true) }}
    {% for grant in grants_result.rows %}
      {{ log("        - " ~ promotion_col(grant, 'privilege') ~ " -> " ~ promotion_col(grant, 'granted_to') ~ " " ~ promotion_col(grant, 'grantee_name'), info=true) }}
    {% endfor %}
  {% endif %}
{% endmacro %}


{% macro ensure_logging_infrastructure() %}
  {% if not execute %}
    {{ return('') }}
  {% endif %}
  {% set database = promotion_database() %}
  {% set log_schema = promotion_audit_schema() %}
  {% set batch_sql %}
    CREATE SCHEMA IF NOT EXISTS {{ database }}.{{ log_schema }};

    CREATE TABLE IF NOT EXISTS {{ database }}.{{ log_schema }}.deployment_log (
      deployment_id NUMBER AUTOINCREMENT PRIMARY KEY,
      deployment_timestamp TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
      operation_type VARCHAR(20) NOT NULL,
      schema_name VARCHAR(255) NOT NULL,
      from_schema VARCHAR(255),
      to_schema VARCHAR(255) NOT NULL,
      version VARCHAR(100),
      job_name VARCHAR(255),
      deployed_by VARCHAR(255) DEFAULT CURRENT_USER(),
      dbt_run_id VARCHAR(255),
      grants_preserved NUMBER,
      status VARCHAR(20) DEFAULT 'SUCCESS',
      error_message VARCHAR(16777216),
      metadata VARIANT
    ) COMMENT = 'atomic_promotion_schema_version=1';

    CREATE TABLE IF NOT EXISTS {{ database }}.{{ log_schema }}.version_inventory (
      inventory_id NUMBER AUTOINCREMENT PRIMARY KEY,
      snapshot_timestamp TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
      schema_name VARCHAR(255) NOT NULL,
      schema_type VARCHAR(20) NOT NULL,
      version VARCHAR(100),
      created_timestamp TIMESTAMP_NTZ,
      row_count NUMBER,
      size_bytes NUMBER,
      table_count NUMBER,
      view_count NUMBER,
      is_current BOOLEAN DEFAULT TRUE,
      metadata VARIANT
    ) COMMENT = 'atomic_promotion_schema_version=1';

    CREATE OR REPLACE VIEW {{ database }}.{{ log_schema }}.deployment_summary AS
    WITH ranked AS (
      SELECT
        schema_name,
        operation_type,
        status,
        deployment_timestamp,
        version,
        deployed_by,
        job_name,
        ROW_NUMBER() OVER (
          PARTITION BY schema_name, operation_type, status
          ORDER BY deployment_timestamp DESC
        ) AS rn_operation,
        ROW_NUMBER() OVER (
          PARTITION BY schema_name
          ORDER BY deployment_timestamp DESC
        ) AS rn_schema
      FROM {{ database }}.{{ log_schema }}.deployment_log
    )
    SELECT
      schema_name,
      MAX(CASE WHEN operation_type = 'PROMOTE' AND status = 'SUCCESS' AND rn_operation = 1 THEN deployment_timestamp END) AS last_promotion,
      MAX(CASE WHEN operation_type = 'PROMOTE' AND status = 'SUCCESS' AND rn_operation = 1 THEN version END) AS last_promoted_version,
      MAX(CASE WHEN operation_type = 'ROLLBACK' AND status = 'SUCCESS' AND rn_operation = 1 THEN deployment_timestamp END) AS last_rollback,
      CASE
        WHEN MAX(CASE WHEN operation_type = 'ROLLBACK' AND status = 'SUCCESS' AND rn_operation = 1 THEN deployment_timestamp END)
             > MAX(CASE WHEN operation_type = 'PROMOTE' AND status = 'SUCCESS' AND rn_operation = 1 THEN deployment_timestamp END)
          THEN 'ROLLED_BACK'
        WHEN MAX(CASE WHEN operation_type = 'PROMOTE' AND status = 'SUCCESS' AND rn_operation = 1 THEN deployment_timestamp END) IS NOT NULL
          THEN 'PROMOTED'
        ELSE 'UNKNOWN'
      END AS current_state,
      COUNT(CASE WHEN operation_type = 'PROMOTE' AND status = 'SUCCESS' THEN 1 END) AS total_promotions,
      COUNT(CASE WHEN operation_type = 'ROLLBACK' AND status = 'SUCCESS' THEN 1 END) AS total_rollbacks,
      COUNT(CASE WHEN status = 'FAILED' THEN 1 END) AS total_failures,
      MAX(CASE WHEN rn_schema = 1 THEN deployment_timestamp END) AS last_deployment,
      MAX(CASE WHEN rn_schema = 1 THEN deployed_by END) AS last_deployed_by,
      MAX(CASE WHEN rn_schema = 1 THEN job_name END) AS last_job_name
    FROM ranked
    GROUP BY schema_name
  {% endset %}
  {% do run_query(batch_sql) %}
  {{ log("Audit tables are ready in " ~ database ~ "." ~ log_schema, info=true) }}
{% endmacro %}


{% macro log_deployment(operation_type, schema_name, from_schema, to_schema, version, job_name=none, grants_count=0) %}
  {% set database = promotion_database() %}
  {% set log_schema = promotion_audit_schema() %}
  {% set job_label = none if job_name is none or (job_name | string | trim) == '' else job_name | string %}
  {% if job_label is not none and job_label | length > 255 %}
    {{ exceptions.raise_compiler_error("job_name must be 255 characters or fewer.") }}
  {% endif %}
  {% set insert_sql %}
    INSERT INTO {{ database }}.{{ log_schema }}.deployment_log (
      operation_type,
      schema_name,
      from_schema,
      to_schema,
      version,
      job_name,
      dbt_run_id,
      grants_preserved,
      metadata
    )
    SELECT
      {{ promotion_sql_literal(operation_type) }},
      {{ promotion_sql_literal(schema_name) }},
      {{ promotion_sql_literal(from_schema) }},
      {{ promotion_sql_literal(to_schema) }},
      {{ promotion_sql_literal(version) }},
      {{ promotion_sql_literal(job_label) }},
      {{ promotion_sql_literal(invocation_id) }},
      {{ grants_count | int }},
      OBJECT_CONSTRUCT(
        'target', {{ promotion_sql_literal(target.name) }},
        'database', {{ promotion_sql_literal(database) }},
        'package_version', {{ promotion_sql_literal(atomic_promotion_version()) }}
      )
  {% endset %}
  {% do run_query(insert_sql) %}
{% endmacro %}


{% macro update_version_inventory(database, promoted, version) %}
  {% if promoted | length == 0 %}
    {{ return('') }}
  {% endif %}
  {% set log_schema = promotion_audit_schema() %}
  {% set version_sql = promotion_sql_literal(version) %}
  {% do run_query("UPDATE " ~ database ~ "." ~ log_schema ~ ".version_inventory SET is_current = FALSE WHERE is_current = TRUE") %}
  {% set insert_sql %}
    INSERT INTO {{ database }}.{{ log_schema }}.version_inventory (
      schema_name,
      schema_type,
      version,
      created_timestamp,
      is_current
    )
    SELECT e.schema_name, e.schema_type, e.version, s.created, TRUE
    FROM (
      {% for item in promoted %}
        SELECT '{{ item['base_schema'] }}' AS schema_name, 'PRODUCTION' AS schema_type, {{ version_sql }} AS version
        UNION ALL
        SELECT '{{ item['build_schema'] }}', 'BUILD', {{ version_sql }}
        UNION ALL
        SELECT '{{ item['previous_schema'] }}', 'BACKUP', CAST(NULL AS VARCHAR)
        {% if not loop.last %}UNION ALL{% endif %}
      {% endfor %}
    ) e
    INNER JOIN {{ database }}.information_schema.schemata s
      ON s.schema_name = e.schema_name
  {% endset %}
  {% do run_query(insert_sql) %}
  {{ log("Version inventory updated", info=true) }}
{% endmacro %}


{% macro check_logging_tables() %}
  {% if not execute %}
    {{ return('') }}
  {% endif %}
  {% set database = promotion_database() %}
  {% set log_schema = promotion_audit_schema() %}
  {% set query %}
    SELECT table_name, table_type
    FROM {{ database }}.information_schema.tables
    WHERE table_schema = '{{ log_schema | upper }}'
    ORDER BY table_name
  {% endset %}
  {% set result = run_query(query) %}
  {{ log("", info=true) }}
  {{ log("Audit objects in " ~ database ~ "." ~ log_schema ~ ":", info=true) }}
  {{ result.print_table() }}
  {{ log("Total: " ~ result.rows | length, info=true) }}
{% endmacro %}
