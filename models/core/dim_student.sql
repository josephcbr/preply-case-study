with students as (
    select * from {{ ref('stg_students') }}
),

paid_hours as (
    select
        *,
        max(payment_rk) over (partition by student_id) as max_payment_rk
    from {{ ref('fct_student_paid_hours') }}
),

latest_cycle as (
    select
        student_id,
        valid_to as latest_cycle_end_date
    from paid_hours
    where payment_rk = max_payment_rk
)

select
    students.student_id,
    students.joined_at,
    students.country_code,
    students.acquisition_channel,
    students.persona,
    students.first_subject,
    case
        when latest_cycle.latest_cycle_end_date is null then 'Inactive'
        when
            {{ var('current_date') }} <= latest_cycle.latest_cycle_end_date
            then 'Active'
        else 'Expired'
    end as student_status,
    latest_cycle.latest_cycle_end_date
from students
left join latest_cycle
    on students.student_id = latest_cycle.student_id
