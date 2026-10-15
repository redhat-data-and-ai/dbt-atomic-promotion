{{ config(materialized='table') }}

select
    order_id,
    status,
    amount
from {{ ref('stg_orders') }}
where status = 'completed'
