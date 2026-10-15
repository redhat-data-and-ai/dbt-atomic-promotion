# Operator guide

This package promotes Snowflake schemas for one dbt project. It does not migrate data between databases, and it does not rebuild tables in the production schema. The first-run sequence is the [ten steps](quickstart.md). A complete project for those steps is [examples/shop](../examples/shop/README.md).

## Access

Run dbt as a role that owns the project schemas. That role needs to:

- create and clone schemas in the target database
- `SHOW GRANTS` on those schemas and on a table in each schema
- `SHOW FUTURE GRANTS IN SCHEMA` on those schemas
- `GRANT` the privileges it copies
- `ALTER SCHEMA ... SWAP WITH` and `ALTER SCHEMA ... RENAME TO`
- create the audit schema (`promotion_logs` unless you change `promotion_log_schema`)

Review grants on the audit schema after the first run. The log contains schema names, the dbt target name, the database name, and the package version. It does not store keys or passwords.

## What each phase does

`promote_all` runs three phases.

**Phase 1.** For every selected schema, clone `BUILD_<SCHEMA>_<VERSION>` to `<SCHEMA>_SWAP`. Copy schema grants (except ownership), `SELECT` on existing tables, views, and external tables, and future grants on tables, views, external tables, and materialized views. Rebuild views whose SQL still points at the build schema. Each expected grant must show up on the swap schema. If one is missing, every swap schema created in this run is dropped and production is unchanged.

The first promotion of a schema that does not exist yet has nothing to copy. The swap schema is renamed to the production name in phase 2, and phase 3 does not create a `_PREVIOUS` schema.

**Phase 2.** For an existing production schema, `ALTER SCHEMA <schema> SWAP WITH <schema>_SWAP`. For a new schema, rename the swap schema to the production name. Readers of the production name see the new objects after that statement.

**Phase 3.** Drop `<SCHEMA>_PREVIOUS` if it exists, then rename `<SCHEMA>_SWAP` (which now holds the old production objects) to `<SCHEMA>_PREVIOUS`. Only one backup is kept.

Build schemas are not dropped during promotion. Use `cleanup_build_schemas` after you no longer need them for debugging.

## Version label

| Input | Stored suffix |
| --- | --- |
| `1.4.2` | `1_4_2` |
| `1.4.2-20261014T183000` | `1_4_2_20261014_183000` |
| `2026-10-14T18:30:00` | `2026_10_14_18_30_00` |
| `feature_test` | `FEATURE_TEST` |

A `T` is treated as a separator only when it sits between digits. Other characters outside letters, numbers, `.`, `-`, `:`, and `_` are rejected, including `/` and spaces.

If `promote_all` is given `version` and `deployment_version` is also set, they must normalize to the same value.

## Merge request schemas

Set `enable_mr_isolation: true` only for a CI target that should build the whole project into one schema named `MR_<id>`. This uses the GitLab CI variables `CI_PIPELINE_SOURCE`, `CI_MERGE_REQUEST_IID`, and `CI_JOB_NAME`. Lint jobs are left alone. Do not combine this with `deployment_version`. Promotion does not manage `MR_` schemas.

`mr_isolation_targets` defaults to `["ci"]`.

## Verification

Replace the database and schema names with yours.

```sql
SELECT schema_name, created, last_altered
FROM analytics.information_schema.schemata
WHERE schema_name IN (
  'STAGING', 'INTERMEDIATE', 'MARTS',
  'STAGING_PREVIOUS', 'INTERMEDIATE_PREVIOUS', 'MARTS_PREVIOUS'
)
ORDER BY schema_name;

SELECT schema_name
FROM analytics.information_schema.schemata
WHERE schema_name LIKE '%\_SWAP' ESCAPE '\\';

SELECT deployment_timestamp, schema_name, from_schema, to_schema, version, job_name, status
FROM analytics.promotion_logs.deployment_log
ORDER BY deployment_timestamp DESC;

SELECT schema_name, current_state, last_promoted_version, last_promotion, last_rollback
FROM analytics.promotion_logs.deployment_summary
ORDER BY schema_name;
```

The swap query should return no rows after a finished promotion.

## Recovery

**Phase 1 failed.** Production was not swapped. Swap schemas from that attempt are dropped when the grant check fails. Any other phase 1 error can leave `<SCHEMA>_SWAP` behind. Drop those swap schemas, then run prepare and promote again. Do not drop production.

**Phase 2 stopped halfway.** Do not run `promote_all` again. Inspect each schema in the batch:

- If that schema's statement already ran, production has the new objects and `<SCHEMA>_SWAP` has the old ones.
- If it did not run, production is still the old objects and `<SCHEMA>_SWAP` has the new ones.

Pick one outcome and apply it to every schema. One `SWAP WITH` exchanges the two schemas. Run it only on the schemas that are still on the wrong side.

```sql
-- Run this only for schemas that have not moved to the side you want.
ALTER SCHEMA analytics.MARTS SWAP WITH analytics.MARTS_SWAP;
```

After every production schema is the new version, rename each leftover swap schema that holds the old objects:

```sql
DROP SCHEMA IF EXISTS analytics.MARTS_PREVIOUS CASCADE;
ALTER SCHEMA analytics.MARTS_SWAP RENAME TO MARTS_PREVIOUS;
```

If you instead put the old objects back into every production schema, drop the `<SCHEMA>_SWAP` schemas. They hold the build you decided not to keep. There is no `_PREVIOUS` rename in that case.

**Phase 2 finished and phase 3 failed.** Production is already the new version. `<SCHEMA>_SWAP` still holds the old one. Run the rename above for each schema. Then you can use `rollback_previous`.

**Rollback.** `rollback_previous` swaps production with `_PREVIOUS` only when every selected schema has both. After a rollback, `deployment_summary.current_state` is `ROLLED_BACK`. `version_inventory` still describes the last promotion until the next one.

## Cleanup boundaries

`cleanup_build_schemas` reads successful `PROMOTE` rows and drops `BUILD_` schemas from versions older than the retention window. It will not drop:

- `MARTS`, `STAGING`, and other production schemas
- `<SCHEMA>_PREVIOUS`
- `<SCHEMA>_SWAP`
- a build schema that never made it into `deployment_log`

Drop an abandoned build schema yourself once you are sure nothing is reading it:

```sql
DROP SCHEMA IF EXISTS analytics.BUILD_MARTS_1_4_2_20261014_183000 CASCADE;
```

## Orchestrator

Any job runner can call the three commands with the same version. Example for Airflow, using the execution timestamp:

```python
version = "1_4_2_{{ ts_nodash }}"

prepare = (
    "dbt run-operation atomic_promotion.prepare_build_schemas "
    f"--vars \"{{deployment_version: {version}}}\""
)
build = f"dbt build --vars \"{{deployment_version: {version}}}\""
promote = (
    "dbt run-operation atomic_promotion.promote_all "
    f"--args \"{{version: {version}, job_name: nightly}}\""
)
```

Fail the job if promote fails. Do not retry promote blindly after phase 2 has started. Check for `_SWAP` schemas first.

## Troubleshooting

**`promotion_schema_name` is not used and models land in `<target_schema>_<custom_schema>`.**

The root project is missing `macros/generate_schema_name.sql`, or that file does not call `atomic_promotion.promotion_schema_name`.

**`None` has no attribute `table` while parsing.**

`generate_schema_name` runs at parse time. Do not call `get_deployment_version` or any macro that runs a query from the root wrapper. The wrapper should only call `promotion_schema_name`.

**`Database '"analytics"' does not exist` or the build schema is not found.**

Identifiers were quoted. dbt-snowflake quoting should stay false. This package creates and looks up unquoted uppercase names. A quoted lowercase schema is a different schema.

**`Missing build schemas`.**

Prepare and build did not use the same `deployment_version`, the root schema wrapper was missing during `dbt build`, or a model schema was added after prepare. Run prepare again only if you are willing to replace that version's build schemas.

**Grant check failed.**

Production was not swapped. The log lists missing grants as `PRIVILEGE|TARGET|GRANTEE_TYPE|GRANTEE|grant_option`. Usual causes: the dbt role cannot re-grant that privilege, a future grant uses an object type other than a table, view, external table, or materialized view, or a grantee name contains characters outside letters, numbers, `_`, `.`, and `$`. `promotion_verbose: true` prints the captured grants.

**Views in production still read `BUILD_` schemas.**

The view text did not contain `BUILD_<SCHEMA>_<VERSION>` exactly, often because the view was created with a quoted lowercase name or the referenced schema was not in this promotion. Rebuild the view in the build schema and promote again, or alter the view in a swap schema before phase 2.

**Two developers overwrote the same `MARTS` schema.**

Schema names are shared on purpose. Isolate people with separate databases, not with `target.schema` prefixes.
