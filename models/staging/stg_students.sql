with source as (

    select * from {{ ref('raw_students') }}

)

select
    student_id,
    join_ts::timestamp as joined_at,
    country_code,
    acquisition_channel,
    persona,
    first_subject

from source
