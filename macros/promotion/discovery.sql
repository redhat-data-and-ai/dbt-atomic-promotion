{% macro promotion_model_schemas() %}
  {#- Schemas from enabled models, seeds, and snapshots. Defaults to the root project. -#}
  {% if not execute %}
    {{ return([]) }}
  {% endif %}

  {% set package_var = var('promotion_packages', none) %}
  {% if package_var is none %}
    {% set packages = [project_name] %}
  {% elif package_var is string %}
    {% set packages = [package_var] %}
  {% elif package_var is sequence %}
    {% set packages = package_var %}
  {% else %}
    {{ exceptions.raise_compiler_error("promotion_packages must be a package name or a list of package names.") }}
  {% endif %}

  {% set schemas = [] %}
  {% for node in graph.nodes.values() %}
    {% if node.resource_type in ['model', 'seed', 'snapshot']
        and node.package_name in packages
        and node.config.materialized != 'ephemeral' %}
      {% set configured = node.config.schema %}
      {% set schema = (configured | trim) if configured else target.schema %}
      {% if schema and (schema | upper) != 'DBTLOGS' and schema not in schemas %}
        {% do schemas.append(schema) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(schemas) }}
{% endmacro %}


{% macro promotion_skip_schemas() %}
  {% set skip_raw = var('promotion_skip_schemas', []) %}
  {% if skip_raw is string %}
    {% set skip_list = [skip_raw] %}
  {% elif skip_raw is sequence %}
    {% set skip_list = skip_raw %}
  {% else %}
    {{ exceptions.raise_compiler_error("promotion_skip_schemas must be a schema name or a list of schema names.") }}
  {% endif %}
  {% set skip_upper = [] %}
  {% for item in skip_list %}
    {% do promotion_assert_identifier(item, 'promotion_skip_schemas entry') %}
    {% do skip_upper.append(item | upper) %}
  {% endfor %}
  {{ return(skip_upper) }}
{% endmacro %}


{% macro promotion_schemas(explicit=none) %}
  {#-
    Uppercase production schema names to prepare, promote, or roll back.
    Reserved build, swap, and backup names are rejected.
  -#}
  {% if explicit is none %}
    {% set requested = promotion_model_schemas() %}
  {% elif explicit is string %}
    {% set requested = [explicit] %}
  {% elif explicit is sequence %}
    {% set requested = explicit %}
  {% else %}
    {{ exceptions.raise_compiler_error("schemas must be a schema name or a list of schema names.") }}
  {% endif %}

  {% set skip_upper = promotion_skip_schemas() %}
  {% set audit = promotion_audit_schema() | upper %}
  {% set selected = [] %}
  {% for schema in requested %}
    {% do promotion_assert_identifier(schema, 'schema') %}
    {% set schema_upper = schema | upper %}
    {% if schema_upper.startswith('BUILD_') or schema_upper.endswith('_SWAP') or schema_upper.endswith('_PREVIOUS') or '_BACKUP_' in schema_upper %}
      {{ exceptions.raise_compiler_error("Schema '" ~ schema ~ "' uses a name reserved by atomic promotion (BUILD_, _SWAP, _PREVIOUS, _BACKUP_).") }}
    {% elif schema_upper == audit %}
      {{ exceptions.raise_compiler_error("promotion_log_schema '" ~ schema ~ "' cannot be swapped. Keep audit tables in their own schema.") }}
    {% elif schema_upper == 'DBTLOGS' or schema_upper in skip_upper or schema_upper in selected %}
      {#- skipped or already collected -#}
    {% else %}
      {% do selected.append(schema_upper) %}
    {% endif %}
  {% endfor %}
  {{ return(selected) }}
{% endmacro %}


{% macro promotion_existing_schemas(database, names) %}
  {% if names | length == 0 %}
    {{ return([]) }}
  {% endif %}
  {% set check_sql %}
    SELECT schema_name
    FROM {{ database }}.information_schema.schemata
    WHERE schema_name IN (
      {% for name in names %}
        '{{ name | upper }}'{% if not loop.last %},{% endif %}
      {% endfor %}
    )
  {% endset %}
  {% set result = run_query(check_sql) %}
  {% if result is none or result.rows | length == 0 %}
    {{ return([]) }}
  {% endif %}
  {% set column = promotion_result_column(result, 'schema_name') %}
  {{ return(result.columns[column].values() | map('string') | map('upper') | list) }}
{% endmacro %}


{% macro promotion_match_builds(database, base_schemas, version) %}
  {% set version_upper = version | upper %}
  {% set planned = [] %}
  {% set names = [] %}
  {% for schema in base_schemas %}
    {% set prod = schema | upper %}
    {% set build = 'BUILD_' ~ prod ~ '_' ~ version_upper %}
    {% if (build | length) > 255 or (prod ~ '_PREVIOUS') | length > 255 %}
      {{ exceptions.raise_compiler_error("Schema '" ~ prod ~ "' with version '" ~ version_upper ~ "' exceeds Snowflake's 255 character identifier limit.") }}
    {% endif %}
    {% do names.append(prod) %}
    {% do names.append(build) %}
    {% do planned.append({
      'base_schema': prod,
      'build_schema': build,
      'swap_schema': prod ~ '_SWAP',
      'previous_schema': prod ~ '_PREVIOUS',
      'new_version': version_upper
    }) %}
  {% endfor %}

  {% set existing = promotion_existing_schemas(database, names) %}
  {% set ready = [] %}
  {% set missing = [] %}
  {% for item in planned %}
    {% if item['build_schema'] in existing %}
      {% do ready.append({
        'base_schema': item['base_schema'],
        'build_schema': item['build_schema'],
        'swap_schema': item['swap_schema'],
        'previous_schema': item['previous_schema'],
        'new_version': item['new_version'],
        'prod_existed': item['base_schema'] in existing
      }) %}
    {% else %}
      {% do missing.append(item['build_schema']) %}
    {% endif %}
  {% endfor %}
  {{ return({'ready': ready, 'missing': missing}) }}
{% endmacro %}


{% macro promotion_drop_schemas(database, schema_names) %}
  {% if schema_names | length == 0 %}
    {{ return('') }}
  {% endif %}
  {% set drop_sql %}
    {% for name in schema_names %}
      DROP SCHEMA IF EXISTS {{ database }}.{{ name }} CASCADE
      {%- if not loop.last %};{% endif %}
    {% endfor %}
  {% endset %}
  {% do run_query(drop_sql) %}
{% endmacro %}
