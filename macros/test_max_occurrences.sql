{% test max_occurrences(model, column_name, max_count) %}

-- Generic test: fails if any value of column_name appears more than
-- max_count times in model. Used on fct_lessons.lesson_id to guard the
-- assumption that a lesson can be split across at most 2 payment cycles.

select
    {{ column_name }},
    count(*) as n_occurrences

from {{ model }}
group by 1
having count(*) > {{ max_count }}

{% endtest %}
