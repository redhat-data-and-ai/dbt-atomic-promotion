# Engineering standard

Changes should be safe to run on a warehouse with many schemas, many grants, and readers on the production schema names during the build.

## Behavior

- Production schemas change only in phase 2, after every selected schema has been prepared.
- A missing grant, a bad identifier, or an unsupported future grant fails the run before that swap.
- One version label is used for prepare, build, and promote. The normalizer is `normalize_deployment_version`.
- Schema names in this package are unquoted. Snowflake folds them to uppercase. Quoting in the consumer project stays off.
- DDL auto-commits. Docs and logs describe the swap as a sequence of statements. Recovery for a partial phase 2 stays in the operator guide.
- Defaults stay generic: `promotion_logs`, example schemas `staging` and `marts`. No organization names, hosts, or account identifiers.

## Public surface

User-facing macros are listed in [reference.md](reference.md). A new one ships with a reference row, a quickstart or guide mention if operators run it, and a changelog line.

`promotion_schema_name` runs at parse time. It cannot call `run_query` or `get_deployment_version`.

## SQL safety

Interpolate only values that have passed `promotion_assert_identifier`, the version normalizer, or `promotion_grantee_sql`. Grant privileges must match `^[A-Za-z][A-Za-z ]*$`.

Read Snowflake columns through `promotion_col` so `SHOW` results work in either case.

Compare grants as `PRIVILEGE|TARGET|GRANTEE_TYPE|GRANTEE|grant_option`. Require every expected key to be present. Do not require the lists to be equal: the swap schema owner is an extra `OWNERSHIP` row.

## Example project

`examples/shop` is the contract for the happy path: two schemas, a seed, a view in staging, a table and a cross-schema view in marts. Update its README when a step changes.

SQL in that project follows the [dbt style guide](https://docs.getdbt.com/best-practices/how-we-style/1-how-we-style-our-dbt-projects): lowercase keywords, trailing commas, explicit columns.

## Versions

`dbt_project.yml` `version` and `atomic_promotion_version()` move together. Tag the published repository `vX.Y.Z`.
