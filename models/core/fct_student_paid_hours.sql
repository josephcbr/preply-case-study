with payments as (
    select * from {{ ref('stg_payments') }}
)

select
    payment_id,
    student_id,
    paid_at as valid_from,
    paid_at + interval '{{ var('cycle_length') }} days' as valid_to,
    hours_purchased,
    price_per_hour_usd,
    hours_purchased * price_per_hour_usd as payment_amount_usd,
    row_number() over (partition by student_id order by paid_at) as payment_rk

from payments
