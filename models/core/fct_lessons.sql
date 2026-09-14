with lessons_booked as (
    select
        lesson_id,
        student_id,
        booked_at,
        hours_booked
    from {{ ref('stg_lessons') }}
),

paid_hours as (
    select
        payment_id,
        student_id,
        valid_from,
        valid_to,
        hours_purchased,
        price_per_hour_usd,
        payment_amount_usd,
        payment_rk
    from {{ ref('fct_student_paid_hours') }}
),

-- Match every lesson to every payment cycle whose window it falls inside.
-- This is capped at 2-way overlap for this exercise, and the
-- max_occurrences test on lesson_id (fct_lessons.yml) fails the build if
-- any lesson ever matches more than 2 cycles.
lesson_cycle_matches as (

    select
        lessons_booked.lesson_id,
        lessons_booked.student_id,
        lessons_booked.booked_at,
        lessons_booked.hours_booked,
        paid_hours.payment_rk,
        paid_hours.hours_purchased,
        paid_hours.price_per_hour_usd,
        count(paid_hours.payment_rk) over (
            partition by lessons_booked.lesson_id
        ) as cycle_overlap_lessons

    from lessons_booked
    left join paid_hours
        on lessons_booked.student_id = paid_hours.student_id
        and lessons_booked.booked_at >= paid_hours.valid_from
        and lessons_booked.booked_at < paid_hours.valid_to

),

-- The common case: a lesson falls inside exactly one cycle. All of its hours
-- count against that one cycle, no allocation needed.
unambiguous_lessons as (

    select
        lesson_id,
        student_id,
        booked_at,
        payment_rk,
        hours_booked as hours_allocated,
        price_per_hour_usd

    from lesson_cycle_matches
    where cycle_overlap_lessons = 1

),

-- The overlap case: a lesson falls inside both the tail of an expiring cycle
-- and the start of a new one (e.g. the student topped up early). Label the
-- older cycle "a" and the newer one "b" so we can drain "a" first (FIFO).
overlap_sides as (

    select
        lesson_id,
        student_id,
        booked_at,
        hours_booked,
        payment_rk,
        hours_purchased,
        price_per_hour_usd,
        cycle_overlap_lessons,
        row_number() over (
            partition by lesson_id order by payment_rk
        ) as cycle_rk

    from lesson_cycle_matches
    where cycle_overlap_lessons = 2

),

-- flatten the overlap into a single row per lesson.
overlap_lessons as (

    select
        cycle_a.lesson_id,
        cycle_a.student_id,
        cycle_a.booked_at,
        cycle_a.hours_booked,
        cycle_a.payment_rk as cycle_a_payment_rk,
        cycle_a.hours_purchased as cycle_a_hours_purchased,
        cycle_a.price_per_hour_usd as cycle_a_price_per_hour_usd,
        cycle_b.payment_rk as cycle_b_payment_rk,
        cycle_b.price_per_hour_usd as cycle_b_price_per_hour_usd

    from overlap_sides as cycle_a
    inner join overlap_sides as cycle_b
        on cycle_a.lesson_id = cycle_b.lesson_id
        and cycle_a.cycle_rk = 1
        and cycle_b.cycle_rk = 2

),

-- How many of cycle a's hours are already used up by lessons that matched
-- it unambiguously (i.e. booked before the overlap window opened).
cycle_a_unambiguous_usage as (

    select
        student_id,
        payment_rk,
        sum(hours_allocated) as unambiguous_hours_used

    from unambiguous_lessons
    group by 1, 2

),

-- Get how many cycle a hours are left after accounting for the 
-- unambiguous lessons in the cycle.
overlap_lessons_with_capacity as (

    select
        overlap_lessons.lesson_id,
        overlap_lessons.student_id,
        overlap_lessons.booked_at,
        overlap_lessons.hours_booked,
        overlap_lessons.cycle_a_payment_rk,
        overlap_lessons.cycle_a_hours_purchased,
        overlap_lessons.cycle_a_price_per_hour_usd,
        overlap_lessons.cycle_b_payment_rk,
        overlap_lessons.cycle_b_price_per_hour_usd,
        overlap_lessons.cycle_a_hours_purchased
        - coalesce(cycle_a_unambiguous_usage.unambiguous_hours_used, 0)
            as cycle_a_capacity_remaining_static,
        -- Get the total number of hours from lessons in overlap cycles
        -- booked before the current lesson.
        coalesce(
            sum(overlap_lessons.hours_booked) over (
                partition by
                    overlap_lessons.student_id,
                    overlap_lessons.cycle_a_payment_rk,
                    overlap_lessons.cycle_b_payment_rk
                order by overlap_lessons.booked_at
                rows between unbounded preceding and 1 preceding
            ),
            0
        ) as cum_hours_before_this_lesson

    from overlap_lessons
    left join cycle_a_unambiguous_usage
        on overlap_lessons.student_id = cycle_a_unambiguous_usage.student_id
        and overlap_lessons.cycle_a_payment_rk = cycle_a_unambiguous_usage.payment_rk

),

-- Drain cycle a's remaining balance first; anything left over spills to b.
-- This naturally splits a single lesson across both cycles when it straddles
-- cycle a running out mid-lesson.
overlap_lessons_split as (

    select
        lesson_id,
        student_id,
        booked_at,
        cycle_a_payment_rk,
        cycle_b_payment_rk,
        cycle_a_price_per_hour_usd,
        cycle_b_price_per_hour_usd,
        greatest(
            0,
            least(
                hours_booked,
                cycle_a_capacity_remaining_static - cum_hours_before_this_lesson
            )
        ) as hours_from_cycle_a,
        hours_booked - greatest(
            0,
            least(
                hours_booked,
                cycle_a_capacity_remaining_static - cum_hours_before_this_lesson
            )
        ) as hours_from_cycle_b

    from overlap_lessons_with_capacity

),

-- Explode out the lessons to get 1 row per lesson per cycle where hours were allocated.
overlap_lessons_exploded as (

    select
        lesson_id,
        student_id,
        booked_at,
        cycle_a_payment_rk as payment_rk,
        hours_from_cycle_a as hours_allocated,
        cycle_a_price_per_hour_usd as price_per_hour_usd
    from overlap_lessons_split
    where hours_from_cycle_a > 0

    union all

    select
        lesson_id,
        student_id,
        booked_at,
        cycle_b_payment_rk as payment_rk,
        hours_from_cycle_b as hours_allocated,
        cycle_b_price_per_hour_usd as price_per_hour_usd
    from overlap_lessons_split
    where hours_from_cycle_b > 0

),

-- Combine unambiguous lessons with overlap lessons. One row per (lesson, contributing cycle)
-- where a split lesson now contributes one row per cycle it drew hours from.
lesson_cycle_allocations as (

    select
        lesson_id,
        student_id,
        booked_at,
        payment_rk,
        hours_allocated,
        price_per_hour_usd
    from unambiguous_lessons

    union all

    select
        lesson_id,
        student_id,
        booked_at,
        payment_rk,
        hours_allocated,
        price_per_hour_usd
    from overlap_lessons_exploded

)

select
    lesson_cycle_allocations.lesson_id,
    lesson_cycle_allocations.student_id,
    lesson_cycle_allocations.booked_at,
    lesson_cycle_allocations.hours_allocated,
    paid_hours.payment_rk,
    paid_hours.valid_from,
    paid_hours.valid_to,
    paid_hours.hours_purchased as total_cycle_hours,
    lesson_cycle_allocations.price_per_hour_usd,
    paid_hours.hours_purchased
    - sum(lesson_cycle_allocations.hours_allocated) over (
        partition by lesson_cycle_allocations.student_id, paid_hours.payment_rk
        order by lesson_cycle_allocations.booked_at
        rows between unbounded preceding and current row
    ) as remaining_cycle_hours

from lesson_cycle_allocations
inner join paid_hours
    on lesson_cycle_allocations.student_id = paid_hours.student_id
    and lesson_cycle_allocations.payment_rk = paid_hours.payment_rk
