# Security

These macros run as the dbt Snowflake role. They create schemas, clone data, copy grants, and swap production schemas.

Use a role that owns the project schemas and can administer only the database those schemas live in. Do not use a role that can grant `ACCOUNTADMIN` or operate unrelated databases.

`deployment_version`, schema names, and grant targets are checked before they are placed into SQL. Labels may contain letters, numbers, dots, dashes, colons, and underscores. Grant grantees must be plain identifiers. This is not a general SQL sanitizer for view text: view definitions are read back from Snowflake and re-created.

The audit tables record the operation, schema, version, job name, dbt invocation id, target name, and database name.

Report a vulnerability through the private advisory flow of the repository where this package is published. Do not open a public issue for an unfixed security bug.
