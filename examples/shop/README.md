# Shop example

`stg_orders` is a view in `STAGING`. `orders` is a table in `MARTS`. `orders_summary` is a view in `MARTS` that reads `STAGING`. Both schemas are promoted together, and the view is rewritten to read `STAGING`.

Copy `profiles.yml.example` to `profiles.yml`. Use a database you can drop. Do not commit `profiles.yml`.

```bash
dbt deps

VERSION="1_0_0_$(date -u +%Y%m%d_%H%M%S)"
dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: ${VERSION}}"
dbt build --vars "{deployment_version: ${VERSION}}"
dbt run-operation atomic_promotion.promote_all --args "{version: ${VERSION}, job_name: shop_release}"
```

On a new database, prepare creates empty `BUILD_STAGING_<VERSION>` and `BUILD_MARTS_<VERSION>`. After promote, `STAGING` and `MARTS` exist and there is no `_PREVIOUS` schema. The view DDL should name `STAGING`.

```sql
select * from <database>.marts.orders order by order_id;
select * from <database>.marts.orders_summary order by status;
select get_ddl('view', '<database>.marts.orders_summary');
```

Repeat prepare, build, and promote with a new `VERSION`. `<SCHEMA>_PREVIOUS` then holds the first release.

```bash
dbt run-operation atomic_promotion.rollback_previous --args "{job_name: shop_release}"
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{num_to_keep: 1, dry_run: true}"
```
