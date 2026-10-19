# Contributing

Issues and changes belong on the repository where this package is published.

The local check is [examples/shop](examples/shop/README.md). Run prepare, build, and promote twice, on two version labels, in a database you can rebuild. Then roll back and clean up. `dbt parse` checks that the schema wrapper loads. It does not run the promotion SQL.

- Keep Snowflake identifiers unquoted. Validate them before interpolating them into SQL.
- Normalize versions only in `normalize_deployment_version`. Do not query Snowflake from `promotion_schema_name`. From that macro, call other package macros with the `atomic_promotion.` prefix.
- Default names stay generic (`promotion_logs`, `staging`, `marts`). Do not add organization-specific databases, roles, hosts, or schema names.
- User-facing macros are listed in [docs/reference.md](docs/reference.md).
- Bump `version` in `dbt_project.yml` and `atomic_promotion_version()` together, and add a `CHANGELOG.md` entry.
- Snowflake DDL auto-commits. Do not describe the swap batch as a single transaction.

Tag a published release `vX.Y.Z` to match `dbt_project.yml`. The license is Apache-2.0.
