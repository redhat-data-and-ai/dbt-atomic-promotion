{% macro rewrite_views_for_production_refs(database, swap_schema, configured_schemas, new_version) %}
  {#-
    Point views in the swap schema at production schemas instead of build schemas.
    GET_DDL needs a literal object name, so each view is fetched on its own.
  -#}
  {% set version_upper = new_version | upper %}
  {% set version_lower = new_version | lower %}
  {% set views_sql %}
    SELECT table_name
    FROM {{ database }}.information_schema.views
    WHERE table_schema = '{{ swap_schema | upper }}'
  {% endset %}
  {% set views_result = run_query(views_sql) %}
  {% set views_to_rebuild = [] %}

  {% for view_row in views_result.rows %}
    {% set view_name = promotion_col(view_row, 'table_name') %}
    {% do promotion_assert_identifier(view_name, 'view') %}
    {% set full_view_name = database ~ "." ~ swap_schema ~ "." ~ view_name %}
    {% set ddl_sql %}
      SELECT REGEXP_SUBSTR(
        GET_DDL('VIEW', '{{ full_view_name }}'),
        'AS[[:space:]]+((?:WITH|SELECT).*)',
        1,
        1,
        'is',
        1
      ) AS view_query
    {% endset %}
    {% set ddl_result = run_query(ddl_sql) %}
    {% set view_query = promotion_col(ddl_result.rows[0], 'view_query') if ddl_result.rows else '' %}
    {% if view_query %}
      {% set query_text = view_query | string | trim %}
      {% set query_head = query_text | upper %}
      {% if query_head[:6] == 'SELECT' or query_head[:4] == 'WITH' %}
        {% set ns = namespace(query=query_text) %}
        {% for schema_name in configured_schemas %}
          {% set ns.query = ns.query | replace('BUILD_' ~ (schema_name | upper) ~ '_' ~ version_upper, schema_name | upper) %}
          {% set ns.query = ns.query | replace('build_' ~ (schema_name | lower) ~ '_' ~ version_lower, schema_name | lower) %}
        {% endfor %}
        {% if ns.query != query_text %}
          {% set ns.query = ns.query | trim %}
          {% if ns.query[-1:] == ';' %}
            {% set ns.query = ns.query[:-1] | trim %}
          {% endif %}
          {% if 'BUILD_' in (ns.query | upper) %}
            {{ log("      View " ~ view_name ~ " still references a BUILD_ schema. Promote that schema in the same run.", info=true) }}
          {% endif %}
          {% do views_to_rebuild.append({'name': full_view_name, 'query': ns.query}) %}
        {% endif %}
      {% else %}
        {{ log("      Skipped " ~ view_name ~ " because its query did not start with SELECT or WITH.", info=true) }}
      {% endif %}
    {% else %}
      {{ log("      Skipped " ~ view_name ~ " because its query could not be read.", info=true) }}
    {% endif %}
  {% endfor %}

  {% for view in views_to_rebuild %}
    {% do run_query("CREATE OR REPLACE VIEW " ~ view['name'] ~ " AS " ~ view['query']) %}
  {% endfor %}
  {{ log("      Rebuilt " ~ (views_to_rebuild | length) ~ " view(s) to reference production schemas", info=true) }}
  {{ return(views_to_rebuild | length) }}
{% endmacro %}


{% macro promotion_collect_grants(database, ready) %}
  {% set prepared = [] %}
  {% for item in ready %}
    {% set ns = namespace(schema_grants=none, object_grants=[], future_grants=[]) %}
    {% if item['prod_existed'] %}
      {% set ns.schema_grants = capture_schema_grants(database, item['base_schema']) %}
      {% set ns.object_grants = capture_object_grants(database, item['base_schema']) %}
      {% set ns.future_grants = capture_future_grants(database, item['base_schema']) %}
      {#- Render before creating swap schemas so a bad grant name fails closed. -#}
      {% do render_schema_grant_sql(database, item['swap_schema'], ns.schema_grants) %}
      {% do render_object_grant_sql(database, item['swap_schema'], ns.object_grants) %}
      {% do render_future_grant_sql(database, item['swap_schema'], ns.future_grants) %}
      {{ log("      Captured " ~ (ns.schema_grants.rows | length) ~ " schema grants for " ~ item['base_schema'], info=true) }}
      {% if ns.object_grants | length > 0 %}
        {{ log("      Captured SELECT for " ~ (ns.object_grants | length) ~ " role(s) from " ~ item['base_schema'], info=true) }}
      {% endif %}
      {% if ns.future_grants | length > 0 %}
        {{ log("      Captured " ~ (ns.future_grants | length) ~ " future grant(s) on " ~ item['base_schema'], info=true) }}
      {% endif %}
    {% else %}
      {{ log("      " ~ item['base_schema'] ~ " does not exist yet, so there are no grants to copy", info=true) }}
    {% endif %}
    {% do prepared.append({
      'base_schema': item['base_schema'],
      'build_schema': item['build_schema'],
      'swap_schema': item['swap_schema'],
      'previous_schema': item['previous_schema'],
      'new_version': item['new_version'],
      'prod_existed': item['prod_existed'],
      'schema_grants': ns.schema_grants,
      'object_grants': ns.object_grants,
      'future_grants': ns.future_grants
    }) %}
  {% endfor %}
  {{ return(prepared) }}
{% endmacro %}


{% macro promote_phase_prepare(database, ready, version, rewrite_schemas) %}
  {{ log("Phase 1: clone builds into swap schemas, copy grants, and rebuild views", info=true) }}
  {% set with_grants = promotion_collect_grants(database, ready) %}
  {% set created = [] %}
  {% set done = [] %}
  {% for item in with_grants %}
    {{ log("  Preparing " ~ item['base_schema'], info=true) }}
    {% do run_query("CREATE OR REPLACE SCHEMA " ~ database ~ "." ~ item['swap_schema'] ~ " CLONE " ~ database ~ "." ~ item['build_schema']) %}
    {% do created.append(item['swap_schema']) %}
    {{ log("      Cloned " ~ item['build_schema'] ~ " -> " ~ item['swap_schema'], info=true) }}
    {% set grant_result = apply_and_validate_grants(
      database,
      item['swap_schema'],
      item['schema_grants'] if item['prod_existed'] else none,
      item['object_grants'],
      item['future_grants']
    ) %}
    {% if not grant_result['success'] %}
      {% do promotion_drop_schemas(database, created) %}
      {{ exceptions.raise_compiler_error("Grant check failed for " ~ item['base_schema'] ~ ". Swap schemas were dropped. Production was not changed.") }}
    {% endif %}
    {% do rewrite_views_for_production_refs(database, item['swap_schema'], rewrite_schemas, version) %}
    {% do done.append({
      'base_schema': item['base_schema'],
      'build_schema': item['build_schema'],
      'swap_schema': item['swap_schema'],
      'previous_schema': item['previous_schema'],
      'new_version': version,
      'prod_existed': item['prod_existed'],
      'grants_count': grant_result['expected'],
      'object_grants_count': grant_result['object_grants']
    }) %}
  {% endfor %}
  {{ log("Phase 1 complete for " ~ (done | length) ~ " schema(s)", info=true) }}
  {{ return(done) }}
{% endmacro %}


{% macro promote_phase_swap(database, promoted) %}
  {% if promoted | length == 0 %}
    {{ return('') }}
  {% endif %}
  {{ log("Phase 2: swapping production schemas. If this stops halfway, do not run promote_all again.", info=true) }}
  {% set batch_sql %}
    {% for item in promoted %}
      {% if item['prod_existed'] %}
        ALTER SCHEMA {{ database }}.{{ item['base_schema'] }} SWAP WITH {{ database }}.{{ item['swap_schema'] }}
      {% else %}
        ALTER SCHEMA {{ database }}.{{ item['swap_schema'] }} RENAME TO {{ item['base_schema'] }}
      {% endif %}
      {%- if not loop.last %};{% endif %}
    {% endfor %}
  {% endset %}
  {{ _log_sql_verbose("Swap statements", batch_sql) }}
  {% do run_query(batch_sql) %}
  {% for item in promoted %}
    {% if item['prod_existed'] %}
      {{ log("  Swapped " ~ item['base_schema'] ~ " with " ~ item['swap_schema'], info=true) }}
    {% else %}
      {{ log("  Renamed " ~ item['swap_schema'] ~ " to " ~ item['base_schema'] ~ " for the first promotion", info=true) }}
    {% endif %}
  {% endfor %}
  {{ log("Phase 2 complete", info=true) }}
{% endmacro %}


{% macro promote_phase_backup(database, promoted) %}
  {% set to_backup = [] %}
  {% for item in promoted %}
    {% if item['prod_existed'] %}
      {% do to_backup.append(item) %}
    {% endif %}
  {% endfor %}
  {% if to_backup | length == 0 %}
    {{ log("Phase 3: no previous production schema to keep", info=true) }}
    {{ return('') }}
  {% endif %}
  {{ log("Phase 3: keep the previous production schemas as _PREVIOUS", info=true) }}
  {% set batch_sql %}
    {% for item in to_backup %}
      DROP SCHEMA IF EXISTS {{ database }}.{{ item['previous_schema'] }} CASCADE;
      ALTER SCHEMA IF EXISTS {{ database }}.{{ item['swap_schema'] }} RENAME TO {{ item['previous_schema'] }}
      {%- if not loop.last %};{% endif %}
    {% endfor %}
  {% endset %}
  {{ _log_sql_verbose("Backup statements", batch_sql) }}
  {% do run_query(batch_sql) %}
  {% for item in to_backup %}
    {{ log("  " ~ item['swap_schema'] ~ " -> " ~ item['previous_schema'], info=true) }}
  {% endfor %}
  {{ log("Phase 3 complete", info=true) }}
{% endmacro %}


{% macro promote_all(version=none, schemas=none, job_name=none) %}
  {#- Phase 1 checks grants. Phase 2 swaps. Phase 3 renames the old schemas to <SCHEMA>_PREVIOUS. -#}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {% set normalized = promotion_resolve_version(version) %}
  {% set database = promotion_database() %}
  {% set selected = promotion_schemas(schemas) %}
  {% if selected | length == 0 %}
    {{ exceptions.raise_compiler_error("No schemas to promote. Add a schema to models, seeds, or snapshots, or pass schemas.") }}
  {% endif %}
  {% set skip_upper = promotion_skip_schemas() %}
  {% if skip_upper | length > 0 %}
    {{ log("Skipping schemas: " ~ (skip_upper | join(', ')), info=true) }}
  {% endif %}

  {% do ensure_logging_infrastructure() %}
  {% set found = promotion_match_builds(database, selected, normalized) %}
  {% if found['missing'] | length > 0 %}
    {{ exceptions.raise_compiler_error("Missing build schemas: " ~ (found['missing'] | join(', ')) ~ ". Run prepare_build_schemas and dbt build with deployment_version " ~ normalized ~ ".") }}
  {% endif %}

  {{ log("", info=true) }}
  {{ log("Promoting " ~ (found['ready'] | length) ~ " schema(s) at version " ~ normalized, info=true) }}
  {% set promoted = promote_phase_prepare(database, found['ready'], normalized, selected) %}
  {% do promote_phase_swap(database, promoted) %}
  {% do promote_phase_backup(database, promoted) %}

  {% for item in promoted %}
    {% do log_deployment(
      'PROMOTE',
      item['base_schema'],
      item['build_schema'],
      item['base_schema'],
      normalized,
      job_name,
      item['grants_count']
    ) %}
  {% endfor %}
  {% do update_version_inventory(database, promoted, normalized) %}
  {{ log("Promotion complete for " ~ normalized ~ ".", info=true) }}
  {{ log("", info=true) }}
{% endmacro %}


{% macro rollback_previous(schemas=none, job_name=none) %}
  {#-
    Swap each selected schema with its _PREVIOUS backup.
    Refuses to start unless every selected schema has a backup, so a subset cannot move alone.
  -#}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {% set database = promotion_database() %}
  {% set selected = promotion_schemas(schemas) %}
  {% if selected | length == 0 %}
    {{ exceptions.raise_compiler_error("No schemas to roll back.") }}
  {% endif %}
  {% do ensure_logging_infrastructure() %}

  {% set names = [] %}
  {% for schema in selected %}
    {% do names.append(schema) %}
    {% do names.append(schema ~ '_PREVIOUS') %}
  {% endfor %}
  {% set existing = promotion_existing_schemas(database, names) %}
  {% set missing = [] %}
  {% for schema in selected %}
    {% if schema not in existing or (schema ~ '_PREVIOUS') not in existing %}
      {% do missing.append(schema) %}
    {% endif %}
  {% endfor %}
  {% if missing | length > 0 %}
    {{ exceptions.raise_compiler_error("Nothing was swapped. These schemas are missing a production schema or a _PREVIOUS backup: " ~ (missing | join(', ')) ~ ".") }}
  {% endif %}

  {{ log("Rolling back " ~ (selected | length) ~ " schema(s).", info=true) }}
  {% set batch_sql %}
    {% for schema in selected %}
      ALTER SCHEMA {{ database }}.{{ schema }} SWAP WITH {{ database }}.{{ schema }}_PREVIOUS
      {%- if not loop.last %};{% endif %}
    {% endfor %}
  {% endset %}
  {% do run_query(batch_sql) %}
  {% for schema in selected %}
    {% do log_deployment('ROLLBACK', schema, schema ~ '_PREVIOUS', schema, none, job_name, 0) %}
    {{ log("  Swapped " ~ schema ~ " with " ~ schema ~ "_PREVIOUS", info=true) }}
  {% endfor %}
  {{ log("Rollback complete. deployment_summary.current_state is ROLLED_BACK. version_inventory is refreshed on the next promotion.", info=true) }}
{% endmacro %}
