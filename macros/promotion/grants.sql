{% macro promotion_privilege_sql(privilege) %}
  {% set text = privilege | string %}
  {% if not modules.re.match('^[A-Za-z][A-Za-z ]*$', text) %}
    {{ exceptions.raise_compiler_error("Refusing to copy privilege '" ~ text ~ "'.") }}
  {% endif %}
  {{ return(text | upper) }}
{% endmacro %}


{% macro promotion_grant_flag(grant_option) %}
  {% if grant_option in [true, 'true', 'TRUE', 'True'] %}
    {{ return('true') }}
  {% endif %}
  {{ return('false') }}
{% endmacro %}


{% macro promotion_grant_option_sql(grant_option) %}
  {% if promotion_grant_flag(grant_option) == 'true' %}
    {{ return(' WITH GRANT OPTION') }}
  {% endif %}
  {{ return('') }}
{% endmacro %}


{% macro promotion_grant_key(privilege, granted_to, grantee_name, grant_option, target='SCHEMA') %}
  {{ return(
    (privilege | string | upper)
    ~ '|' ~ (target | string | upper)
    ~ '|' ~ (granted_to | string | upper)
    ~ '|' ~ (grantee_name | string | upper)
    ~ '|' ~ promotion_grant_flag(grant_option)
  ) }}
{% endmacro %}


{% macro promotion_missing_keys(expected_keys, actual_keys) %}
  {% set missing = [] %}
  {% for key in expected_keys %}
    {% if key not in actual_keys %}
      {% do missing.append(key) %}
    {% endif %}
  {% endfor %}
  {{ return(missing) }}
{% endmacro %}


{% macro promotion_future_target(grant_on) %}
  {% set kind = grant_on | string | upper | replace(' ', '_') %}
  {% if kind == 'TABLE' %}
    {{ return('FUTURE TABLES') }}
  {% elif kind == 'VIEW' %}
    {{ return('FUTURE VIEWS') }}
  {% elif kind == 'EXTERNAL_TABLE' %}
    {{ return('FUTURE EXTERNAL TABLES') }}
  {% elif kind == 'MATERIALIZED_VIEW' %}
    {{ return('FUTURE MATERIALIZED VIEWS') }}
  {% else %}
    {{ return(none) }}
  {% endif %}
{% endmacro %}


{% macro promotion_grantee_sql(database, granted_to, grantee_name) %}
  {% set kind = (granted_to | string | upper) if granted_to is not none else '' %}
  {% set name = grantee_name | string %}
  {% if not modules.re.match('^[A-Za-z_][A-Za-z0-9_.$]*$', name) %}
    {{ exceptions.raise_compiler_error("Refusing to copy a grant to '" ~ name ~ "'. The grantee must be a plain identifier.") }}
  {% endif %}
  {% if kind == 'DATABASE_ROLE' %}
    {% if '.' in name %}
      {{ return('DATABASE ROLE ' ~ name) }}
    {% else %}
      {{ return('DATABASE ROLE ' ~ database ~ '.' ~ name) }}
    {% endif %}
  {% elif kind in ['ROLE', 'USER', 'SHARE'] %}
    {{ return(kind ~ ' ' ~ name) }}
  {% else %}
    {{ exceptions.raise_compiler_error("Refusing to copy a grant for grantee type '" ~ kind ~ "'.") }}
  {% endif %}
{% endmacro %}


{% macro capture_schema_grants(database, schema_name) %}
  {% set capture_sql %}
    SHOW GRANTS ON SCHEMA {{ database }}.{{ schema_name }}
  {% endset %}
  {{ _log_sql_verbose("Capturing schema grants from " ~ schema_name, capture_sql) }}
  {% set result = run_query(capture_sql) %}
  {{ _log_grants_detail(result, schema_name) }}
  {{ return(result) }}
{% endmacro %}


{% macro capture_object_grants(database, schema_name) %}
  {#-
    Sample SELECT grants from one table, then re-apply that set to every
    table, view, and external table in the swap schema.
  -#}
  {% set grants_list = [] %}
  {% set get_table_sql %}
    SELECT table_name
    FROM {{ database }}.information_schema.tables
    WHERE table_schema = '{{ schema_name | upper }}'
      AND table_type = 'BASE TABLE'
    LIMIT 1
  {% endset %}
  {% set table_result = run_query(get_table_sql) %}
  {% if table_result is none or table_result.rows | length == 0 %}
    {{ return([]) }}
  {% endif %}
  {% set sample_table = promotion_col(table_result.rows[0], 'table_name') %}
  {% do promotion_assert_identifier(sample_table, 'sampled table') %}
  {{ _log_verbose("Sampling SELECT grants from table " ~ sample_table) }}
  {% set table_grants = run_query("SHOW GRANTS ON TABLE " ~ database ~ "." ~ schema_name ~ "." ~ sample_table) %}
  {% for row in table_grants.rows %}
    {% set privilege = promotion_col(row, 'privilege') %}
    {% if privilege is not none and privilege | string | upper == 'SELECT' %}
      {% do grants_list.append({
        'privilege': 'SELECT',
        'grantee_name': promotion_col(row, 'grantee_name'),
        'granted_to': promotion_col(row, 'granted_to'),
        'grant_option': promotion_col(row, 'grant_option')
      }) %}
    {% endif %}
  {% endfor %}
  {{ return(grants_list) }}
{% endmacro %}


{% macro render_schema_grant_sql(database, schema_name, grants_result) %}
  {% if grants_result is none %}
    {{ return('') }}
  {% endif %}
  {% set statements = [] %}
  {% for grant in grants_result.rows %}
    {% set privilege = promotion_col(grant, 'privilege') %}
    {% if privilege is not none and privilege | string | upper != 'OWNERSHIP' %}
      {% set statement %}
        GRANT {{ promotion_privilege_sql(privilege) }} ON SCHEMA {{ database }}.{{ schema_name }}
        TO {{ promotion_grantee_sql(database, promotion_col(grant, 'granted_to'), promotion_col(grant, 'grantee_name')) }}{{ promotion_grant_option_sql(promotion_col(grant, 'grant_option')) }}
      {% endset %}
      {% do statements.append(statement | trim) %}
    {% endif %}
  {% endfor %}
  {{ return(statements | join(';\n')) }}
{% endmacro %}


{% macro render_object_grant_sql(database, schema_name, object_grants) %}
  {% set statements = [] %}
  {% for grant in object_grants %}
    {% set grantee = promotion_grantee_sql(database, grant['granted_to'], grant['grantee_name']) %}
    {% set option = promotion_grant_option_sql(grant['grant_option']) %}
    {% do statements.append('GRANT SELECT ON ALL TABLES IN SCHEMA ' ~ database ~ '.' ~ schema_name ~ ' TO ' ~ grantee ~ option) %}
    {% do statements.append('GRANT SELECT ON ALL VIEWS IN SCHEMA ' ~ database ~ '.' ~ schema_name ~ ' TO ' ~ grantee ~ option) %}
    {% do statements.append('GRANT SELECT ON ALL EXTERNAL TABLES IN SCHEMA ' ~ database ~ '.' ~ schema_name ~ ' TO ' ~ grantee ~ option) %}
  {% endfor %}
  {{ return(statements | join(';\n')) }}
{% endmacro %}


{% macro capture_future_grants(database, schema_name) %}
  {#-
    Future grants keep access working for objects created after the swap.
    Unsupported object types stop promotion before any production schema changes.
  -#}
  {% set result = run_query("SHOW FUTURE GRANTS IN SCHEMA " ~ database ~ "." ~ schema_name) %}
  {% if result is none %}
    {{ return([]) }}
  {% endif %}
  {% set grants = [] %}
  {% set unsupported = [] %}
  {% for row in result.rows %}
    {% set privilege = promotion_col(row, 'privilege') %}
    {% set grant_on = promotion_col(row, 'grant_on') %}
    {% set ns = namespace(granted=promotion_col(row, 'granted_to')) %}
    {% if ns.granted is none %}
      {% set ns.granted = promotion_col(row, 'grant_to') %}
    {% endif %}
    {% set grantee = promotion_col(row, 'grantee_name') %}
    {% set target = promotion_future_target(grant_on) %}
    {% if privilege is not none and (privilege | string | upper) == 'OWNERSHIP' %}
      {#- Ownership of future objects stays with the role that creates them. -#}
    {% elif privilege is none or target is none %}
      {% do unsupported.append((privilege | string) ~ " on " ~ (grant_on | string) ~ " to " ~ (grantee | string)) %}
    {% else %}
      {% do grants.append({
        'privilege': privilege | string | upper,
        'grant_on': grant_on | string,
        'target': target,
        'granted_to': ns.granted,
        'grantee_name': grantee,
        'grant_option': promotion_col(row, 'grant_option')
      }) %}
    {% endif %}
  {% endfor %}
  {% if unsupported | length > 0 %}
    {{ exceptions.raise_compiler_error("Future grants on " ~ schema_name ~ " use object types this package does not copy yet: " ~ (unsupported | join('; ')) ~ ". Tables, views, external tables, and materialized views are supported.") }}
  {% endif %}
  {{ return(grants) }}
{% endmacro %}


{% macro render_future_grant_sql(database, schema_name, future_grants) %}
  {% set statements = [] %}
  {% for grant in future_grants %}
    {% set statement %}
      GRANT {{ promotion_privilege_sql(grant['privilege']) }} ON {{ grant['target'] }} IN SCHEMA {{ database }}.{{ schema_name }}
      TO {{ promotion_grantee_sql(database, grant['granted_to'], grant['grantee_name']) }}{{ promotion_grant_option_sql(grant['grant_option']) }}
    {% endset %}
    {% do statements.append(statement | trim) %}
  {% endfor %}
  {{ return(statements | join(';\n')) }}
{% endmacro %}


{% macro promotion_schema_grant_keys(grants_result) %}
  {% set keys = [] %}
  {% if grants_result is none %}
    {{ return([]) }}
  {% endif %}
  {% for grant in grants_result.rows %}
    {% set privilege = promotion_col(grant, 'privilege') %}
    {% if privilege is not none and (privilege | string | upper) != 'OWNERSHIP' %}
      {% set key = promotion_grant_key(
        privilege,
        promotion_col(grant, 'granted_to'),
        promotion_col(grant, 'grantee_name'),
        promotion_col(grant, 'grant_option'),
        'SCHEMA'
      ) %}
      {% if key not in keys %}
        {% do keys.append(key) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(keys) }}
{% endmacro %}


{% macro promotion_future_grant_keys(future_grants) %}
  {% set keys = [] %}
  {% for grant in future_grants %}
    {% set key = promotion_grant_key(
      grant['privilege'],
      grant['granted_to'],
      grant['grantee_name'],
      grant['grant_option'],
      grant['target']
    ) %}
    {% if key not in keys %}
      {% do keys.append(key) %}
    {% endif %}
  {% endfor %}
  {{ return(keys) }}
{% endmacro %}


{% macro apply_grant_sql(description, grant_sql) %}
  {% if grant_sql | trim == '' %}
    {{ return(0) }}
  {% endif %}
  {{ _log_sql_verbose(description, grant_sql) }}
  {% do run_query(grant_sql) %}
  {{ return(grant_sql.split(';') | length) }}
{% endmacro %}


{% macro promotion_sample_table(database, schema_name) %}
  {% set table_result = run_query(
    "SELECT table_name FROM " ~ database ~ ".information_schema.tables "
    ~ "WHERE table_schema = '" ~ (schema_name | upper) ~ "' AND table_type = 'BASE TABLE' LIMIT 1"
  ) %}
  {% if table_result is none or table_result.rows | length == 0 %}
    {{ return(none) }}
  {% endif %}
  {% set sample_table = promotion_col(table_result.rows[0], 'table_name') %}
  {% do promotion_assert_identifier(sample_table, 'sampled table') %}
  {{ return(sample_table) }}
{% endmacro %}


{% macro promotion_select_grant_keys(database, schema_name, table_name) %}
  {% set result = run_query("SHOW GRANTS ON TABLE " ~ database ~ "." ~ schema_name ~ "." ~ table_name) %}
  {% set keys = [] %}
  {% for row in result.rows %}
    {% set privilege = promotion_col(row, 'privilege') %}
    {% if privilege is not none and (privilege | string | upper) == 'SELECT' %}
      {% set key = promotion_grant_key(
        'SELECT',
        promotion_col(row, 'granted_to'),
        promotion_col(row, 'grantee_name'),
        promotion_col(row, 'grant_option'),
        'TABLE'
      ) %}
      {% if key not in keys %}
        {% do keys.append(key) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(keys) }}
{% endmacro %}


{% macro apply_and_validate_grants(database, schema_name, expected_grants_result, object_grants, future_grants=none) %}
  {#-
    Copy schema grants, sampled SELECT grants, and future grants.
    Every expected grant must be present afterward. OWNERSHIP is skipped.
    Extra grants, such as the swap schema owner, do not fail the check.
  -#}
  {% if future_grants is none %}
    {% set future_grants = [] %}
  {% endif %}
  {% set schema_sql = render_schema_grant_sql(database, schema_name, expected_grants_result) %}
  {% set object_sql = render_object_grant_sql(database, schema_name, object_grants) %}
  {% set future_sql = render_future_grant_sql(database, schema_name, future_grants) %}
  {% do apply_grant_sql("Applying schema grants to " ~ schema_name, schema_sql) %}
  {% do apply_grant_sql("Applying SELECT grants to " ~ schema_name, object_sql) %}
  {% do apply_grant_sql("Applying future grants to " ~ schema_name, future_sql) %}

  {% if expected_grants_result is none %}
    {{ return({'success': true, 'expected': 0, 'actual': 0, 'object_grants': object_grants | length, 'future_grants': future_grants | length}) }}
  {% endif %}

  {% set expected_keys = promotion_schema_grant_keys(expected_grants_result) %}
  {% set actual_keys = promotion_schema_grant_keys(capture_schema_grants(database, schema_name)) %}
  {% set missing = promotion_missing_keys(expected_keys, actual_keys) %}
  {% if missing | length > 0 %}
    {{ log("Schema grants missing on " ~ schema_name ~ ": " ~ (missing | join(', ')), info=true) }}
    {{ return({'success': false, 'expected': expected_keys | length, 'actual': actual_keys | length, 'object_grants': object_grants | length, 'future_grants': future_grants | length}) }}
  {% endif %}

  {% if object_grants | length > 0 %}
    {% set sample_table = promotion_sample_table(database, schema_name) %}
    {% if sample_table is not none %}
      {% set expected_select = [] %}
      {% for grant in object_grants %}
        {% set key = promotion_grant_key(grant['privilege'], grant['granted_to'], grant['grantee_name'], grant['grant_option'], 'TABLE') %}
        {% if key not in expected_select %}
          {% do expected_select.append(key) %}
        {% endif %}
      {% endfor %}
      {% set actual_select = promotion_select_grant_keys(database, schema_name, sample_table) %}
      {% set missing_select = promotion_missing_keys(expected_select, actual_select) %}
      {% if missing_select | length > 0 %}
        {{ log("SELECT grants missing on " ~ schema_name ~ "." ~ sample_table ~ ": " ~ (missing_select | join(', ')), info=true) }}
        {{ return({'success': false, 'expected': expected_keys | length, 'actual': actual_keys | length, 'object_grants': object_grants | length, 'future_grants': future_grants | length}) }}
      {% endif %}
    {% endif %}
  {% endif %}

  {% if future_grants | length > 0 %}
    {% set expected_future = promotion_future_grant_keys(future_grants) %}
    {% set actual_future = promotion_future_grant_keys(capture_future_grants(database, schema_name)) %}
    {% set missing_future = promotion_missing_keys(expected_future, actual_future) %}
    {% if missing_future | length > 0 %}
      {{ log("Future grants missing on " ~ schema_name ~ ": " ~ (missing_future | join(', ')), info=true) }}
      {{ return({'success': false, 'expected': expected_keys | length, 'actual': actual_keys | length, 'object_grants': object_grants | length, 'future_grants': future_grants | length}) }}
    {% endif %}
  {% endif %}

  {{ log("      Grants checked (" ~ (expected_keys | length) ~ " schema, " ~ (object_grants | length) ~ " SELECT roles, " ~ (future_grants | length) ~ " future)", info=true) }}
  {{ return({'success': true, 'expected': expected_keys | length, 'actual': actual_keys | length, 'object_grants': object_grants | length, 'future_grants': future_grants | length}) }}
{% endmacro %}
