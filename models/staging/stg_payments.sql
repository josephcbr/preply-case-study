with source as (

    select * from {{ ref('raw_payments') }}

)

select
    payment_id,
    student_id,
    payment_ts::timestamp as paid_at,
    hours::numeric as hours_purchased,
    price_per_hour_usd::numeric as price_per_hour_usd

from source
