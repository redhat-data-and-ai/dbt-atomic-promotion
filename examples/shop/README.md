# Shop example

A two-schema project that shows why Snowflake and dbt belong in the same promotion.

`stg_orders` is a view in `STAGING`. `orders` is a table in `MARTS`. `orders_summary` is a view in `MARTS` that reads `STAGING`. dbt builds both schemas under one version label. Snowflake then swaps them together, and the package rewrites `orders_summary` so production reads `STAGING` instead of `BUILD_STAGING_<VERSION>`.

The generic sequence is the [ten steps](../../docs/quickstart.md). The commands below are that sequence for this folder.

## Files

| Path | Role |
| --- | --- |
| `packages.yml` | Installs this package from `../..` |
| `macros/generate_schema_name.sql` | Sends versioned builds to `BUILD_<SCHEMA>_<VERSION>` |
| `seeds/raw_orders.csv` | Three orders: two completed, one pending |
| `models/staging/stg_orders.sql` | View in `STAGING` |
| `models/marts/orders.sql` | Table of completed orders in `MARTS` |
| `models/marts/orders_summary.sql` | View in `MARTS` over staging |

Copy `profiles.yml.example` to `profiles.yml` and fill in the account, user, role, warehouse, and database. Do not commit `profiles.yml`.

Use a database you can drop. The role must be able to create schemas, clone, swap, and grant.

## 1. Install

From this directory:

```bash
dbt deps
```

## 2. Choose a version

```bash
VERSION="1_0_0_$(date -u +%Y%m%d_%H%M%S)"
```

Keep this shell open, or export `VERSION`, so the next commands share it.

## 3. Prepare

```bash
dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: ${VERSION}}"
```

On a new database this creates empty `BUILD_STAGING_<VERSION>` and `BUILD_MARTS_<VERSION>`. `STAGING` and `MARTS` do not exist yet.

## 4. Build and test

```bash
dbt build --vars "{deployment_version: ${VERSION}}"
```

Expect the seed, `stg_orders`, `orders`, and `orders_summary` in the build schemas, plus the column tests. Production schemas are still absent.

## 5. Promote

```bash
dbt run-operation atomic_promotion.promote_all --args "{version: ${VERSION}, job_name: shop_release}"
```

Snowflake now has `STAGING` and `MARTS`. There is no `_PREVIOUS` schema on this first promotion. The build schemas remain.

## 6. Read production

```sql
select * from <database>.marts.orders order by order_id;
-- order_id 1 amount 10
-- order_id 3 amount 5

select * from <database>.marts.orders_summary order by status;
-- completed, order_count 2, amount_total 15
-- pending,   order_count 1, amount_total 20

select get_ddl('view', '<database>.marts.orders_summary');
```

The view DDL should reference `STAGING`, not `BUILD_STAGING_`.

```sql
select schema_name, current_state, last_promoted_version
from <database>.promotion_logs.deployment_summary
order by schema_name;
```

`current_state` is `PROMOTED` for `STAGING` and `MARTS`.

## 7. Promote a second version

Change the seed or a model, then repeat prepare, build, and promote with a new label.

```bash
VERSION="1_0_1_$(date -u +%Y%m%d_%H%M%S)"

dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: ${VERSION}}"
dbt build --vars "{deployment_version: ${VERSION}}"
dbt run-operation atomic_promotion.promote_all --args "{version: ${VERSION}, job_name: shop_release}"
```

Prepare clones the current `STAGING` and `MARTS` into the new build schemas, so the build starts from production. After promote, `<SCHEMA>_PREVIOUS` holds the first release.

Readers of `MARTS` keep using that name the whole time. They switch only when the swap statement runs.

## 8. Roll back

```bash
dbt run-operation atomic_promotion.rollback_previous --args "{job_name: shop_release}"
```

`STAGING` and `MARTS` swap back with `STAGING_PREVIOUS` and `MARTS_PREVIOUS`. The command refuses to start if either backup is missing. `deployment_summary.current_state` becomes `ROLLED_BACK`.

## 9. Clean build schemas

```bash
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{dry_run: true}"
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{num_to_keep: 1}"
```

The dry run lists `BUILD_` schemas from older promoted versions. The second command drops them. `STAGING`, `MARTS`, and the `_PREVIOUS` schemas stay.

## Why both schemas move together

`orders_summary` selects from `stg_orders`. If only `MARTS` were promoted, the rewritten view would point at the old `STAGING`. The default `promote_all` swaps every schema in this project in one run. Pass `schemas` only when the models you built do not read a schema you are leaving behind.
