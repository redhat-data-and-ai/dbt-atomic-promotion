{{ config(materialized='view') }}

select
    status,
    count(*) as order_count,
    sum(amount) as amount_total
from {{ ref('stg_orders') }}
group by status
