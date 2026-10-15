# Contributing

Issues and changes belong on the repository where this package is published.

## Local check

Install the folder into a dbt project that already targets Snowflake. Use a database you can rebuild. Point `promotion_log_schema` at an empty schema.

1. Add the root `generate_schema_name` wrapper from `examples/generate_schema_name.sql`.
2. Run `prepare_build_schemas`, `dbt build`, and `promote_all` twice, with a new version the second time.
3. Confirm production schemas swapped, `<SCHEMA>_PREVIOUS` holds the previous objects, and views in production do not reference `BUILD_`.
4. Run `rollback_previous` and confirm the previous objects are back.
5. Run `cleanup_build_schemas` with `dry_run: true`, then without it, and confirm only old `BUILD_` schemas were dropped.

`dbt parse` on the consumer project checks that the schema wrapper loads. It does not execute the promotion SQL.

The local check project is [examples/shop](examples/shop/README.md). Run it twice, on two version labels, in a database you can rebuild.

## Package conventions

The engineering bar for changes is [docs/standards.md](docs/standards.md). In short:

- Keep Snowflake identifiers unquoted. Validate them before interpolating them into SQL.
- Normalize versions only in `normalize_deployment_version`, and call that from schema naming. Do not run queries from `promotion_schema_name`.
- Default schema names stay generic (`promotion_logs`). Do not add organization-specific databases, roles, hosts, or schema names.
- New user-facing macros go in [docs/reference.md](docs/reference.md) in the same change.
- Bump `version` in `dbt_project.yml` and `atomic_promotion_version()` together, and add a `CHANGELOG.md` entry.
- Snowflake DDL auto-commits. Do not describe the swap batch as a single transaction.

## Publishing

When this folder becomes its own repository, tag releases as `vX.Y.Z` to match `dbt_project.yml`. Consumers pin that tag in `packages.yml`. The license is Apache-2.0; change `LICENSE` before the first public tag if the project needs a different license.
