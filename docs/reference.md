# Macro reference

Call these from the root project with the `atomic_promotion` namespace. Other macros in the package are implementation details.

## promotion_schema_name

```jinja
{% macro generate_schema_name(custom_schema_name, node) %}
    {{ return(atomic_promotion.promotion_schema_name(custom_schema_name, node)) }}
{% endmacro %}
```

| `deployment_version` | Result |
| --- | --- |
| Unset | `MARTS` for `+schema: marts`. Models with no schema use `target.schema`, uppercased. |
| Set | `BUILD_<SCHEMA>_<VERSION>` for tables, incremental models, views, seeds, and snapshots. |

Runs at parse time. It must not query Snowflake.

## prepare_build_schemas

```bash
dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: 1_0_0_20261015_183000}"
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `schemas` | Every model, seed, and snapshot schema in the root project | Limit the clone to these schemas |

`deployment_version` is required and comes from `--vars`.

## promote_all

```bash
dbt run-operation atomic_promotion.promote_all --args "{version: 1_0_0_20261015_183000, job_name: release}"
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `version` | `deployment_version` var | Build suffix to promote. Required if the var is also unset. If both are set, they must match. |
| `schemas` | Same discovery as prepare | Schemas to swap together |
| `job_name` | null | Stored on `deployment_log.job_name` |

Fails if any selected build schema is missing.

## rollback_previous

```bash
dbt run-operation atomic_promotion.rollback_previous --args "{job_name: release}"
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `schemas` | Discovered project schemas | Must each have `<SCHEMA>_PREVIOUS` |
| `job_name` | null | Stored on the rollback rows |

## cleanup_build_schemas

```bash
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{num_to_keep: 5, dry_run: true}"
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `num_to_keep` | var `cleanup_build_schemas_to_keep`, else 5 | Promoted versions to retain |
| `dry_run` | false | Print the drop list and skip the drops |

## check_logging_tables

```bash
dbt run-operation atomic_promotion.check_logging_tables
```

Prints the tables and views in `promotion_log_schema`.

## get_deployment_version

Returns the normalized `deployment_version` var and logs it. Do not call it from `generate_schema_name`. Use `normalize_deployment_version` there; it does not query the warehouse.

## Project variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `deployment_version` | unset | Version for prepare and for `dbt build` |
| `promotion_log_schema` | `promotion_logs` | Audit schema. Must not also be a model schema. |
| `promotion_skip_schemas` | `[]` | Schemas left out of prepare, promote, and rollback |
| `promotion_packages` | the root project | Package names whose models count toward schema discovery |
| `cleanup_build_schemas_to_keep` | `5` | Retention for cleanup |
| `promotion_verbose` | `false` | Log grant rows and SQL. `PROMOTION_VERBOSE=true` does the same. |
| `enable_mr_isolation` | `false` | Optional GitLab CI schema `MR_<id>` |
| `mr_isolation_targets` | `["ci"]` | dbt targets where that isolation applies |
