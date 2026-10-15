# Ten steps

dbt builds a candidate. Snowflake swaps it into the schema names readers already use. Do these steps in order, with one version label from prepare through promote.

The [shop example](../examples/shop/README.md) is the same sequence with models, a seed, and a view that crosses schemas. Use that folder if you want files to copy.

## 1. Install the package

In the dbt project that owns the models:

```yaml
packages:
  - local: /path/to/dbt-atomic-promotion
```

After this folder is published, pin a tag instead:

```yaml
packages:
  - git: "https://github.com/<owner>/dbt-atomic-promotion.git"
    revision: v0.2.0
```

Run `dbt deps`.

## 2. Keep schema names stable

In `dbt_project.yml`, turn quoting off and give each layer one schema. Those names are the production names in every environment. Separate environments with databases, not with `target.schema` prefixes.

```yaml
quoting:
  database: false
  schema: false
  identifier: false

models:
  my_project:
    staging:
      +schema: staging
    marts:
      +schema: marts

vars:
  promotion_log_schema: promotion_logs
```

## 3. Add the schema wrapper

dbt reads `generate_schema_name` only from the root project. Create `macros/generate_schema_name.sql`:

```jinja
{% macro generate_schema_name(custom_schema_name, node) %}
    {{ return(atomic_promotion.promotion_schema_name(custom_schema_name, node)) }}
{% endmacro %}
```

Without this file, `dbt build` writes into the production schemas even when `deployment_version` is set.

## 4. Pick one version label

```bash
VERSION="1_0_0_$(date -u +%Y%m%d_%H%M%S)"
echo "$VERSION"
```

Use that value for prepare, build, and promote. `1.0.0-20261015T183000` is stored as `1_0_0_20261015_183000`.

## 5. Prepare the build schemas

```bash
dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: ${VERSION}}"
```

Each production schema is cloned to `BUILD_<SCHEMA>_<VERSION>`. If production does not exist yet, the build schema is created empty. Run this once per version. Running it again replaces that version's build schemas.

## 6. Build and test into the build schemas

```bash
dbt build --vars "{deployment_version: ${VERSION}}"
```

Tables, views, incremental models, seeds, and snapshots land in the build schemas. Incremental models continue from the cloned production data. Production schemas are unchanged.

## 7. Promote

```bash
dbt run-operation atomic_promotion.promote_all --args "{version: ${VERSION}, job_name: release}"
```

Phase 1 clones each build into `<SCHEMA>_SWAP`, copies grants, and points views at production schema names. Phase 2 swaps those schemas into production. Phase 3 renames the old production schemas to `<SCHEMA>_PREVIOUS`.

The first promotion has no previous schema, so phase 3 does not create a backup.

## 8. Check the result

```sql
select schema_name
from analytics.information_schema.schemata
where schema_name like '%\_SWAP' escape '\\';

select schema_name, current_state, last_promoted_version
from analytics.promotion_logs.deployment_summary
order by schema_name;
```

The first query returns no rows after a finished promotion. `current_state` is `PROMOTED`. A view in `MARTS` that reads staging should name `STAGING`, not `BUILD_STAGING_...`.

```sql
select get_ddl('view', 'analytics.marts.orders_summary');
```

## 9. Roll back one step

Only after a promotion that created `<SCHEMA>_PREVIOUS`:

```bash
dbt run-operation atomic_promotion.rollback_previous --args "{job_name: release}"
```

Every selected schema must have a backup, or the command swaps nothing. `deployment_summary.current_state` becomes `ROLLED_BACK`.

## 10. Drop old build schemas

```bash
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{dry_run: true}"
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{num_to_keep: 5}"
```

This drops `BUILD_` schemas from promoted versions older than the newest five. It leaves production, `_PREVIOUS`, and any build schema that was never promoted.

## What you should see

| After | Production | `BUILD_<SCHEMA>_<VERSION>` | `<SCHEMA>_PREVIOUS` |
| --- | --- | --- | --- |
| Prepare, first release | Absent | Empty schema | Absent |
| Build | Absent | Models and seeds | Absent |
| Promote, first release | New objects | Still present | Absent |
| Prepare, next release | Current objects | Clone of current | Previous release, if any |
| Promote, next release | New objects | Still present | The objects readers had before this promote |

Build schemas stay until step 10 so you can compare them with production.

## If promote stops

Do not run it again until you know which phase finished. [Recovery](guide.md#recovery) says what to do with leftover `_SWAP` schemas.
