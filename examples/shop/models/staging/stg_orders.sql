select
    order_id,
    status,
    amount
from {{ ref('raw_orders') }}
