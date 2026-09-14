with paid_hours as (

    select
        student_id,
        payment_rk,
        valid_from,
        valid_to,
        hours_purchased,
        price_per_hour_usd,
        date_trunc('day', valid_from)::date as cycle_start_date,
        date_trunc('day', valid_to)::date as cycle_end_date

    from {{ ref('fct_student_paid_hours') }}

),

calendar as (

    select
        date_day,
        week_start_date,
        week_end_date,
        month_start_date,
        month_end_date

    from {{ ref('dim_date') }}

),

students as (

    select
        student_id,
        country_code,
        acquisition_channel,
        persona,
        first_subject

    from {{ ref('dim_student') }}

),

lesson_hours_allocated as (

    select
        student_id,
        payment_rk,
        booked_at,
        hours_allocated

    from {{ ref('fct_lessons') }}

),

-- Fan each cycle out across its calendar days. Capped at current_date: an
-- open cycle only shows the days that have actually happened so far, since
-- days later in its window haven't occurred yet. The grain of this will be
-- student_id, payment_rk, date_day to account for overlapping payment 
-- cycles (doesn't happen in dummy data, but built for real prod scenarios).
cycle_day_spine as (

    select
        paid_hours.student_id,
        paid_hours.payment_rk,
        paid_hours.hours_purchased,
        paid_hours.price_per_hour_usd,
        paid_hours.cycle_start_date,
        paid_hours.cycle_end_date,
        paid_hours.valid_to <= {{ var('current_date') }} as is_cycle_closed,
        calendar.date_day,
        calendar.week_start_date,
        calendar.week_end_date,
        calendar.month_start_date,
        calendar.month_end_date,
        calendar.date_day
        - paid_hours.cycle_start_date
        + 1 as days_elapsed_in_cycle,
        greatest(paid_hours.cycle_end_date - paid_hours.cycle_start_date, 1)
            as total_cycle_days

    from paid_hours
    inner join calendar
        on paid_hours.cycle_start_date <= calendar.date_day
        and paid_hours.cycle_end_date > calendar.date_day
        and calendar.date_day <= {{ var('current_date') }}

),

-- Sum hours by day and payment_rk, so we know how many hours
-- were used each day by payment cycle.
daily_hours_used as (

    select
        student_id,
        payment_rk,
        date_trunc('day', booked_at)::date as date_day,
        sum(hours_allocated) as hours_used_that_day

    from lesson_hours_allocated
    group by 1, 2, 3

),

-- Combine hours used with day spine, coalesce to 0 for 
-- days with no lessons booked.
cycle_day_spine_with_usage as (

    select
        cycle_day_spine.student_id,
        cycle_day_spine.payment_rk,
        cycle_day_spine.hours_purchased,
        cycle_day_spine.price_per_hour_usd,
        cycle_day_spine.cycle_start_date,
        cycle_day_spine.cycle_end_date,
        cycle_day_spine.is_cycle_closed,
        cycle_day_spine.date_day,
        cycle_day_spine.week_start_date,
        cycle_day_spine.week_end_date,
        cycle_day_spine.month_start_date,
        cycle_day_spine.month_end_date,
        cycle_day_spine.days_elapsed_in_cycle,
        cycle_day_spine.total_cycle_days,
        coalesce(daily_hours_used.hours_used_that_day, 0) as hours_used_that_day

    from cycle_day_spine
    left join daily_hours_used
        on cycle_day_spine.student_id = daily_hours_used.student_id
        and cycle_day_spine.payment_rk = daily_hours_used.payment_rk
        and cycle_day_spine.date_day = daily_hours_used.date_day

),

-- Running total of actual hours used so far per cycle. Quiet days (no
-- lesson) contribute 0 and simply carry the prior total forward.
cycle_day_spine_with_cumulative as (

    select
        student_id,
        payment_rk,
        hours_purchased,
        price_per_hour_usd,
        cycle_start_date,
        cycle_end_date,
        is_cycle_closed,
        date_day,
        week_start_date,
        week_end_date,
        month_start_date,
        month_end_date,
        days_elapsed_in_cycle,
        total_cycle_days,
        hours_used_that_day,
        sum(hours_used_that_day) over (
            partition by student_id, payment_rk
            order by date_day
            rows between unbounded preceding and current row
        ) as cumulative_hours_used

    from cycle_day_spine_with_usage

),

-- One row per (student, cycle) with that cycle's own final/latest numbers.
-- Only confirmed once a cycle has closed, used for the historic benchmark below.
cycle_summary as (

    select
        student_id,
        payment_rk,
        max(hours_purchased) as hours_purchased,
        max(total_cycle_days) as total_cycle_days,
        bool_or(is_cycle_closed) as is_cycle_closed,
        max(cumulative_hours_used) as final_cumulative_hours_used

    from cycle_day_spine_with_cumulative
    group by 1, 2

),

-- Actual avg hours per day for completed cycles.
cycle_final_pace as (

    select
        student_id,
        payment_rk,
        case
            when is_cycle_closed
                then final_cumulative_hours_used / total_cycle_days
        end as final_avg_hours_per_day

    from cycle_summary

),

-- Per student, per cycle: average final pace across all of that student's
-- own prior completed cycles — used to de-noise early-cycle predictions below. 
-- avg()/count() skip nulls, so a still-open prior cycle just falls out of the window.
cycle_historic_pace as (

    select
        student_id,
        payment_rk,
        avg(final_avg_hours_per_day) over (
            partition by student_id order by payment_rk
            rows between unbounded preceding and 1 preceding
        ) as historic_avg_hours_per_day,
        count(final_avg_hours_per_day) over (
            partition by student_id order by payment_rk
            rows between unbounded preceding and 1 preceding
        ) as n_historic_completed_cycles

    from cycle_final_pace

),

-- Which pace to project forward with: for the first 14 days of a cycle,
-- its own pace is based on too little data to be reliable, so use this
-- student's historic average pace from their own completed cycles instead
-- (falling back to the current cycle's own pace if they have no history
-- yet — e.g. this is their first cycle). From day 15 on, the cycle has
-- enough of its own data, so it switches to its own pace.
breakage_pace as (

    select
        cycle_day_spine_with_cumulative.student_id,
        cycle_day_spine_with_cumulative.payment_rk,
        cycle_day_spine_with_cumulative.hours_purchased,
        cycle_day_spine_with_cumulative.price_per_hour_usd,
        cycle_day_spine_with_cumulative.cycle_start_date,
        cycle_day_spine_with_cumulative.cycle_end_date,
        cycle_day_spine_with_cumulative.is_cycle_closed,
        cycle_day_spine_with_cumulative.date_day,
        cycle_day_spine_with_cumulative.week_start_date,
        cycle_day_spine_with_cumulative.week_end_date,
        cycle_day_spine_with_cumulative.month_start_date,
        cycle_day_spine_with_cumulative.month_end_date,
        cycle_day_spine_with_cumulative.days_elapsed_in_cycle,
        cycle_day_spine_with_cumulative.total_cycle_days,
        cycle_day_spine_with_cumulative.hours_used_that_day,
        cycle_day_spine_with_cumulative.cumulative_hours_used,
        cycle_historic_pace.historic_avg_hours_per_day,
        cycle_historic_pace.n_historic_completed_cycles,
        cycle_day_spine_with_cumulative.cumulative_hours_used
        / cycle_day_spine_with_cumulative.days_elapsed_in_cycle
            as current_cycle_avg_hours_per_day,
        case
            when cycle_day_spine_with_cumulative.days_elapsed_in_cycle < 15
                then 'historic_cycle_average'
            else 'current_cycle_pace'
        end as prediction_source,
        case
            when cycle_day_spine_with_cumulative.days_elapsed_in_cycle < 15
                then coalesce(
                    cycle_historic_pace.historic_avg_hours_per_day,
                    cycle_day_spine_with_cumulative.cumulative_hours_used
                    / cycle_day_spine_with_cumulative.days_elapsed_in_cycle
                )
            else
                cycle_day_spine_with_cumulative.cumulative_hours_used
                / cycle_day_spine_with_cumulative.days_elapsed_in_cycle
        end as effective_avg_hours_per_day

    from cycle_day_spine_with_cumulative
    left join cycle_historic_pace
        on cycle_day_spine_with_cumulative.student_id = cycle_historic_pace.student_id
        and cycle_day_spine_with_cumulative.payment_rk = cycle_historic_pace.payment_rk

),

-- actual_breakage is only known once a cycle has closed, and is the same
-- value on every day of that cycle (the final tally), so a chart can show
-- the predicted line converging to it over the course of the cycle.
breakage as (

    select
        student_id,
        payment_rk,
        hours_purchased,
        price_per_hour_usd,
        cycle_start_date,
        cycle_end_date,
        is_cycle_closed,
        date_day,
        week_start_date,
        week_end_date,
        month_start_date,
        month_end_date,
        days_elapsed_in_cycle,
        total_cycle_days,
        hours_used_that_day,
        cumulative_hours_used,
        current_cycle_avg_hours_per_day,
        historic_avg_hours_per_day,
        n_historic_completed_cycles,
        prediction_source,
        -- Floored at cumulative_hours_used: projected usage can never be
        -- less than usage that's already happened. Capped at hours_purchased:
        -- a cycle can't have more hours used against it than it holds
        -- (mirrors the remaining_cycle_hours >= 0 guarantee in fct_lessons).
        least(
            hours_purchased,
            greatest(
                effective_avg_hours_per_day * total_cycle_days,
                cumulative_hours_used
            )
        ) as predicted_hours_used_by_cycle_end,
        -- Guaranteed >= 0: predicted_hours_used_by_cycle_end is capped at
        -- hours_purchased above, so no separate floor is needed here.
        hours_purchased - least(
            hours_purchased,
            greatest(
                effective_avg_hours_per_day * total_cycle_days,
                cumulative_hours_used
            )
        ) as predicted_breakage,
        case
            when is_cycle_closed
                then greatest(
                    0,
                    hours_purchased
                    - max(cumulative_hours_used) over (
                        partition by student_id, payment_rk
                    )
                )
        end as actual_breakage

    from breakage_pace

),

-- Get actual breakage (hours and dollars) per student per payment cycle.
cycle_actual_breakage as (

    select distinct
        student_id,
        payment_rk,
        actual_breakage,
        actual_breakage * price_per_hour_usd as actual_breakage_usd

    from breakage

),

-- Per student, per cycle: average actual_breakage over that student's own
-- preceding 1/3/6 cycles, in hours and in dollars. Also includes a count of
-- the number of cycles included to determine maturity of the trailing
-- averages — the same count applies to both the hours and dollar averages,
-- since actual_breakage_usd is null exactly when actual_breakage is null.
cycle_trailing_breakage as (

    select
        student_id,
        payment_rk,
        avg(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 1 preceding and 1 preceding
        ) as avg_actual_breakage_last_1_cycle,
        avg(actual_breakage_usd) over (
            partition by student_id order by payment_rk
            rows between 1 preceding and 1 preceding
        ) as avg_actual_breakage_usd_last_1_cycle,
        count(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 1 preceding and 1 preceding
        ) as n_cycles_last_1,
        avg(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 3 preceding and 1 preceding
        ) as avg_actual_breakage_last_3_cycles,
        avg(actual_breakage_usd) over (
            partition by student_id order by payment_rk
            rows between 3 preceding and 1 preceding
        ) as avg_actual_breakage_usd_last_3_cycles,
        count(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 3 preceding and 1 preceding
        ) as n_cycles_last_3,
        avg(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 6 preceding and 1 preceding
        ) as avg_actual_breakage_last_6_cycles,
        avg(actual_breakage_usd) over (
            partition by student_id order by payment_rk
            rows between 6 preceding and 1 preceding
        ) as avg_actual_breakage_usd_last_6_cycles,
        count(actual_breakage) over (
            partition by student_id order by payment_rk
            rows between 6 preceding and 1 preceding
        ) as n_cycles_last_6

    from cycle_actual_breakage

)

select
    breakage.student_id,
    breakage.payment_rk,
    breakage.date_day,
    breakage.week_start_date,
    breakage.week_end_date,
    breakage.month_start_date,
    breakage.month_end_date,
    breakage.days_elapsed_in_cycle,
    breakage.total_cycle_days,
    breakage.cycle_start_date,
    breakage.cycle_end_date,
    breakage.is_cycle_closed,
    breakage.hours_purchased,
    breakage.price_per_hour_usd,
    breakage.hours_used_that_day,
    breakage.cumulative_hours_used,
    breakage.current_cycle_avg_hours_per_day,
    breakage.historic_avg_hours_per_day,
    breakage.n_historic_completed_cycles,
    breakage.prediction_source,
    breakage.predicted_hours_used_by_cycle_end,
    breakage.predicted_breakage,
    breakage.actual_breakage,
    students.country_code,
    students.acquisition_channel,
    students.persona,
    students.first_subject,
    -- Commission: 20% of the value of hours actually booked.
    breakage.hours_used_that_day * breakage.price_per_hour_usd * 0.20
        as commission_usd_that_day,
    breakage.cumulative_hours_used * breakage.price_per_hour_usd * 0.20
        as cumulative_commission_usd,
    -- Breakage in dollars: 100% of the value of unbooked hours.
    breakage.predicted_breakage * breakage.price_per_hour_usd
        as predicted_breakage_usd,
    -- hours_purchased - predicted_breakage = the hours expected to actually
    -- get booked (capped at hours_purchased even if the pace projection
    -- overshoots it — a student can't earn commission on hours they don't
    -- have), so this is 20% of that projected booked value.
    (breakage.hours_purchased - breakage.predicted_breakage)
    * breakage.price_per_hour_usd * 0.20
        as predicted_commission_usd,
    (breakage.predicted_breakage * breakage.price_per_hour_usd)
    + (
        (breakage.hours_purchased - breakage.predicted_breakage)
        * breakage.price_per_hour_usd * 0.20
    ) as predicted_total_revenue_usd,
    -- actual_ columns are null until the cycle closes, same as actual_breakage.
    breakage.actual_breakage * breakage.price_per_hour_usd
        as actual_breakage_usd,
    (breakage.hours_purchased - breakage.actual_breakage)
    * breakage.price_per_hour_usd * 0.20
        as actual_commission_usd,
    (breakage.actual_breakage * breakage.price_per_hour_usd)
    + (
        (breakage.hours_purchased - breakage.actual_breakage)
        * breakage.price_per_hour_usd * 0.20
    ) as actual_total_revenue_usd,
    -- Only include if there is at least one closed cycle to average over.
    case
        when cycle_trailing_breakage.n_cycles_last_1 = 1
            then cycle_trailing_breakage.avg_actual_breakage_last_1_cycle
    end as avg_actual_breakage_last_1_cycle,
    case
        when cycle_trailing_breakage.n_cycles_last_1 = 1
            then cycle_trailing_breakage.avg_actual_breakage_usd_last_1_cycle
    end as avg_actual_breakage_usd_last_1_cycle,
    -- Only include if there is at least 3 closed cycles to average over.
    case
        when cycle_trailing_breakage.n_cycles_last_3 = 3
            then cycle_trailing_breakage.avg_actual_breakage_last_3_cycles
    end as avg_actual_breakage_last_3_cycles,
    case
        when cycle_trailing_breakage.n_cycles_last_3 = 3
            then cycle_trailing_breakage.avg_actual_breakage_usd_last_3_cycles
    end as avg_actual_breakage_usd_last_3_cycles,
    -- Only include if there is at least 6 closed cycles to average over.
    case
        when cycle_trailing_breakage.n_cycles_last_6 = 6
            then cycle_trailing_breakage.avg_actual_breakage_last_6_cycles
    end as avg_actual_breakage_last_6_cycles,
    case
        when cycle_trailing_breakage.n_cycles_last_6 = 6
            then cycle_trailing_breakage.avg_actual_breakage_usd_last_6_cycles
    end as avg_actual_breakage_usd_last_6_cycles

from breakage
inner join students
    on breakage.student_id = students.student_id
left join cycle_trailing_breakage
    on breakage.student_id = cycle_trailing_breakage.student_id
    and breakage.payment_rk = cycle_trailing_breakage.payment_rk
