# Atomic promotion for dbt on Snowflake

Build the next version beside the schemas readers already use, then swap the names after the build and the grants check out. Production stays `STAGING` and `MARTS`. The candidate lives in `BUILD_<SCHEMA>_<VERSION>`. The previous objects stay as `<SCHEMA>_PREVIOUS`.

Snowflake commits each DDL statement on its own, so a promotion of several schemas is a sequence. A missing grant stops the run before any production schema is swapped.

Run the [shop example](examples/shop/README.md). Macro arguments are in the [reference](docs/reference.md).

## Requirements

- dbt Core 1.6 or newer, and dbt-snowflake
- A role that owns the project schemas and can create, clone, swap, and grant in the target database
- Quoting left off, which is the dbt-snowflake default. These macros use unquoted identifiers. Snowflake stores them in uppercase.

## Install

```yaml
packages:
  - git: "https://github.com/<owner>/dbt-atomic-promotion.git"
    revision: v0.2.0
```

Run `dbt deps`. For a local checkout, use `local: /path/to/dbt-atomic-promotion` instead of the git pin.

## Setup

Give each layer one schema. Separate environments with databases, not with `target.schema` prefixes.

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

dbt reads `generate_schema_name` only from the root project. Add `macros/generate_schema_name.sql` there. A copy is in [`examples/generate_schema_name.sql`](examples/generate_schema_name.sql).

```jinja
{% macro generate_schema_name(custom_schema_name, node) %}
    {{ return(atomic_promotion.promotion_schema_name(custom_schema_name, node)) }}
{% endmacro %}
```

Do not name a schema with a `BUILD_` prefix, a `_SWAP` or `_PREVIOUS` suffix, or `_BACKUP_`.

## Promote

Use one version label for prepare, build, and promote. `1.0.0-20261015T183000` is stored as `1_0_0_20261015_183000`.

```bash
VERSION="1_0_0_$(date -u +%Y%m%d_%H%M%S)"

dbt run-operation atomic_promotion.prepare_build_schemas --vars "{deployment_version: ${VERSION}}"
dbt build --vars "{deployment_version: ${VERSION}}"
dbt run-operation atomic_promotion.promote_all --args "{version: ${VERSION}, job_name: release}"
```

Prepare clones each production schema to `BUILD_<SCHEMA>_<VERSION>`, or creates it empty when production does not exist yet. Running prepare again for the same version replaces that build schema. `dbt build` writes tables, views, incremental models, seeds, and snapshots there. `promote_all` fails if a selected build schema is missing.

Pass `schemas` only when the models you built do not read a schema you are leaving behind. The view rewrite only retargets schemas included in that run.

```bash
dbt run-operation atomic_promotion.rollback_previous --args "{job_name: release}"
dbt run-operation atomic_promotion.cleanup_build_schemas --args "{num_to_keep: 5, dry_run: true}"
```

Rollback does nothing unless every selected schema has `<SCHEMA>_PREVIOUS`. Cleanup drops `BUILD_` schemas from promoted versions older than the newest N. It leaves production, `_PREVIOUS`, `_SWAP`, and build schemas that were never promoted.

Any job runner can call the same three commands with one version. Do not retry `promote_all`. Keep a single active run.

## Airflow

Use one DAG run's logical time as the version, and pass that same value to prepare, `dbt build`, and `promote_all`. `ts_nodash` is `YYYYMMDDTHHMMSS`. The package stores the `T` as an underscore.

`dbt build` has to receive `deployment_version`. A seed task that omits it writes into the production schemas.

Set `max_active_runs` to 1 so two runs cannot swap the same schemas. Prepare and build may retry. Set `retries` to 0 on `promote_all`. A second attempt after phase 2 has started can swap a schema that already moved. If that task fails, follow [If promote stops](#if-promote-stops) before clearing it. Run cleanup only after promote succeeds.

```python
from datetime import datetime

from airflow.decorators import dag
from airflow.operators.bash import BashOperator

DBT = "cd /path/to/dbt_project && dbt"


@dag(
    dag_id="promote_nightly",
    start_date=datetime(2026, 1, 1),
    schedule="0 6 * * *",
    catchup=False,
    max_active_runs=1,
    default_args={"retries": 1},
    tags=["dbt", "promotion"],
)
def promote_nightly():
    prepare = BashOperator(
        task_id="prepare_build_schemas",
        bash_command=(
            f"{DBT} run-operation atomic_promotion.prepare_build_schemas "
            "--vars '{deployment_version: 1_0_0_{{ ts_nodash }}}'"
        ),
    )
    build = BashOperator(
        task_id="dbt_build",
        bash_command=(
            f"{DBT} build "
            "--vars '{deployment_version: 1_0_0_{{ ts_nodash }}}'"
        ),
    )
    promote = BashOperator(
        task_id="promote_all",
        retries=0,
        bash_command=(
            f"{DBT} run-operation atomic_promotion.promote_all "
            "--args '{version: 1_0_0_{{ ts_nodash }}, job_name: nightly}'"
        ),
    )
    cleanup = BashOperator(
        task_id="cleanup_build_schemas",
        bash_command=(
            f"{DBT} run-operation atomic_promotion.cleanup_build_schemas "
            "--args '{num_to_keep: 5}'"
        ),
    )
    prepare >> build >> promote >> cleanup


promote_nightly()
```

Point `DBT` at the project on the worker image. That image needs dbt-snowflake, and `dbt deps` already run. Quoting in the project stays off.

Cosmos can own the tasks instead of bash. The rendered command still needs the same `--vars` on prepare and on `dbt build`, and the same `version` and `job_name` on `atomic_promotion.promote_all`. Leave retries at 0 on that task.

## If promote stops

**Phase 1.** Production was not swapped. A failed grant check drops the swap schemas from that attempt. Drop any `<SCHEMA>_SWAP` left behind, then prepare and promote again.

**Phase 2.** Do not run `promote_all` again. If a schema has not moved yet, swap it. When every production schema holds the new objects, rename the leftover swap schema:

```sql
ALTER SCHEMA analytics.MARTS SWAP WITH analytics.MARTS_SWAP;
DROP SCHEMA IF EXISTS analytics.MARTS_PREVIOUS CASCADE;
ALTER SCHEMA analytics.MARTS_SWAP RENAME TO MARTS_PREVIOUS;
```

**Phase 3.** Production is already the new version. Run the rename above, then `rollback_previous` can put the previous objects back.

## Limits

- Snowflake only.
- Schema grants other than ownership are copied. `SELECT` on existing tables, views, and external tables is copied from one sampled object. Future grants are copied for tables, views, external tables, and materialized views. Other future-grant types stop the promotion before the swap.
- Every expected grant must be present. The lists do not have to match, because the swap schema has its own owner. A missing grant aborts the promotion.
- View SQL is rewritten by replacing `BUILD_<SCHEMA>_<VERSION>`. The query after `AS` must start with `SELECT` or `WITH`.
- Audit tables are created in `promotion_logs` unless `promotion_log_schema` is set: `deployment_log`, `version_inventory`, and `deployment_summary`.

Apache License 2.0. See [LICENSE](LICENSE).
