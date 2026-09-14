with source as (

    select * from {{ ref('raw_lessons') }}

)

select
    lesson_id,
    student_id,
    booking_ts::timestamp as booked_at,
    hours_booked::numeric as hours_booked

from source
