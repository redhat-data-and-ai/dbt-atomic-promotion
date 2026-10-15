{% macro atomic_promotion_version() %}
  {{ return('0.2.0') }}
{% endmacro %}


{% macro promotion_versioned_materializations() %}
  {{ return(['table', 'incremental', 'view', 'seed', 'snapshot']) }}
{% endmacro %}


{% macro promotion_assert_identifier(value, label) %}
  {% if value is none or not modules.re.match('^[A-Za-z_][A-Za-z0-9_]*$', value | string) %}
    {{ exceptions.raise_compiler_error(label ~ " must be an unquoted identifier made of letters, numbers, and underscores. Got: " ~ value) }}
  {% endif %}
{% endmacro %}


{% macro promotion_database() %}
  {% set database = target.database %}
  {% do promotion_assert_identifier(database, 'target.database') %}
  {{ return(database) }}
{% endmacro %}


{% macro promotion_audit_schema() %}
  {% set schema_name = var('promotion_log_schema', 'promotion_logs') %}
  {% do promotion_assert_identifier(schema_name, 'promotion_log_schema') %}
  {{ return(schema_name) }}
{% endmacro %}


{% macro normalize_deployment_version(raw_version) %}
  {#-
    Turn a version label into a Snowflake-safe suffix.
    Dots, dashes, colons, and the ISO "T" separator become underscores.
    Example: 1.4.2-20261014T183000 -> 1_4_2_20261014_183000
  -#}
  {% if raw_version is none or (raw_version | string | trim) == '' %}
    {{ exceptions.raise_compiler_error("deployment_version is required. Example: 1_4_2_20261014_183000") }}
  {% endif %}
  {#- Replace an ISO "T" only when it sits between digits, so words like TEST stay intact. -#}
  {% set normalized = raw_version | string | trim | replace('.', '_') | replace('-', '_') | replace(':', '_') %}
  {% set normalized = modules.re.sub('(?<=[0-9])[Tt](?=[0-9])', '_', normalized) | upper %}
  {% if not modules.re.match('^[A-Za-z0-9_]+$', normalized) or not modules.re.search('[A-Za-z0-9]', normalized) %}
    {{ exceptions.raise_compiler_error("Invalid deployment_version '" ~ raw_version ~ "'. Use letters, numbers, dots, dashes, colons, and underscores. Example: 1.4.2-20261014T183000") }}
  {% endif %}
  {% if normalized | length > 80 %}
    {{ exceptions.raise_compiler_error("deployment_version is " ~ (normalized | length) ~ " characters after normalization. Keep it at or under 80 so schema names stay within 255 characters.") }}
  {% endif %}
  {{ return(normalized) }}
{% endmacro %}


{% macro get_deployment_version() %}
  {% set normalized = normalize_deployment_version(var('deployment_version', none)) %}
  {{ log("Using deployment_version: " ~ normalized, info=true) }}
  {{ return(normalized) }}
{% endmacro %}


{% macro promotion_resolve_version(version_arg) %}
  {% set from_var = var('deployment_version', none) %}
  {% if version_arg is none and from_var is none %}
    {{ exceptions.raise_compiler_error("Pass version to the macro or set deployment_version. Example: 1_4_2_20261014_183000") }}
  {% endif %}
  {% if version_arg is not none and from_var is not none %}
    {% set arg_norm = normalize_deployment_version(version_arg) %}
    {% set var_norm = normalize_deployment_version(from_var) %}
    {% if arg_norm != var_norm %}
      {{ exceptions.raise_compiler_error("version (" ~ arg_norm ~ ") and deployment_version (" ~ var_norm ~ ") do not match. Use one label for prepare, build, and promote.") }}
    {% endif %}
    {{ return(arg_norm) }}
  {% endif %}
  {{ return(normalize_deployment_version(version_arg if version_arg is not none else from_var)) }}
{% endmacro %}


{% macro promotion_sql_literal(value) %}
  {% if value is none %}
    {{ return('NULL') }}
  {% else %}
    {{ return("'" ~ (value | string | replace("'", "''")) ~ "'") }}
  {% endif %}
{% endmacro %}


{% macro promotion_result_column(table, name) %}
  {% set wanted = name | lower %}
  {% for column in table.column_names %}
    {% if column | lower == wanted %}
      {{ return(column) }}
    {% endif %}
  {% endfor %}
  {{ exceptions.raise_compiler_error("Query result has no column named " ~ name ~ ". Columns: " ~ (table.column_names | join(', '))) }}
{% endmacro %}


{% macro promotion_col(row, name) %}
  {% for candidate in [name, name | lower, name | upper] %}
    {% if candidate in row %}
      {{ return(row[candidate]) }}
    {% endif %}
  {% endfor %}
  {{ return(none) }}
{% endmacro %}
