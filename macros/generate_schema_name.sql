{% macro promotion_schema_name(custom_schema_name, node) %}
  {#-
    Schema naming for versioned builds.

    Without deployment_version, a configured schema is uppercased
    (marts becomes MARTS). Models with no schema config use target.schema.
    With deployment_version, tables, views, incremental models, seeds,
    and snapshots are placed in BUILD_<SCHEMA>_<VERSION>.

    dbt only honors generate_schema_name from the root project. Call this
    from a root wrapper. See examples/generate_schema_name.sql.
  -#}
  {% set base_schema = custom_schema_name | trim if custom_schema_name else target.schema %}
  {% do promotion_assert_identifier(base_schema, 'schema') %}
  {% set upper_schema = base_schema | upper %}
  {% if upper_schema.startswith('BUILD_') or upper_schema.endswith('_SWAP') or upper_schema.endswith('_PREVIOUS') or '_BACKUP_' in upper_schema %}
    {{ exceptions.raise_compiler_error("Schema '" ~ base_schema ~ "' uses a name reserved by atomic promotion (BUILD_, _SWAP, _PREVIOUS, _BACKUP_).") }}
  {% endif %}

  {% if var('enable_mr_isolation', false) %}
    {% set mr_targets = var('mr_isolation_targets', ['ci']) %}
    {% set is_mr = env_var('CI_PIPELINE_SOURCE', '') == 'merge_request_event' %}
    {% set is_lint = 'lint' in env_var('CI_JOB_NAME', '') %}
    {% set iid = env_var('CI_MERGE_REQUEST_IID', '') %}
    {% if is_mr and target.name in mr_targets and not is_lint and iid %}
      {% if var('deployment_version', none) is not none %}
        {{ exceptions.raise_compiler_error("deployment_version and merge request schema isolation cannot be used together.") }}
      {% endif %}
      {% if not modules.re.match('^[0-9]+$', iid | string) %}
        {{ exceptions.raise_compiler_error("CI_MERGE_REQUEST_IID must be numeric when merge request schema isolation is on.") }}
      {% endif %}
      {{ return('MR_' ~ iid) }}
    {% endif %}
  {% endif %}

  {% set raw_version = var('deployment_version', none) %}
  {% set materialization = node.config.materialized if node is not none else none %}
  {% if raw_version is not none and materialization in promotion_versioned_materializations() %}
    {% set version = normalize_deployment_version(raw_version) %}
    {% set build_schema = 'BUILD_' ~ (base_schema | upper) ~ '_' ~ version %}
    {% if build_schema | length > 255 %}
      {{ exceptions.raise_compiler_error("Refusing to use schema '" ~ build_schema ~ "' because it is longer than 255 characters.") }}
    {% endif %}
    {{ return(build_schema) }}
  {% endif %}

  {{ return(base_schema | upper) }}
{% endmacro %}
