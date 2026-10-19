# Changelog

## Unreleased

- Call package macros by name from `promotion_schema_name`, so a root `generate_schema_name` wrapper can resolve them at parse time.
- Keep the user docs to the README, the macro reference, and the shop example.

## 0.2.0

- Check grants by privilege and grantee. A missing grant stops promotion before the swap. Extra ownership on the swap schema does not.
- Copy future grants for tables, views, external tables, and materialized views. Other future-grant types stop promotion with the type named in the error.
- Add a shop example project and a macro reference.

## 0.1.0

First public cut of the Snowflake dbt promotion package.

- Clone production schemas into `build_<schema>_<version>`, build there, then swap.
- Copy schema grants and sampled `SELECT` grants, and stop before the swap if schema grant counts do not match.
- Keep the previous production schemas as `<schema>_PREVIOUS`.
- Write `deployment_log`, `version_inventory`, and `deployment_summary` to a configurable audit schema (`promotion_logs` by default).
- Roll back the latest successful promotion and drop build schemas older than a retention window.
