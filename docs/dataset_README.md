# Case Study Dataset

Synthetic dataset for the Analytics Engineer Case Study. Three CSV files sharing the same schema as Preply's raw tables.

## Files

### `raw_students.csv` (3,000 rows)

| Column | Type | Example |
|---|---|---|
| `student_id` | integer | 4670487 |
| `join_ts` | timestamp | 2026-02-17 09:16:29.765 |
| `country_code` | string | ES, US, UK, DE, FR, BR, MX, IT, NL, PL, JP, AR, TR, SE, AU |
| `acquisition_channel` | string | CRM, Paid, Direct & Brand, WoM, Other |
| `persona` | string | working_professional, relocator, exam_prepper, conversationalist |
| `first_subject` | string | english, spanish, french, portuguese, german, italian |

### `raw_payments.csv` (~9,700 rows)

| Column | Type | Example |
|---|---|---|
| `payment_id` | integer | 150000000 |
| `student_id` | integer | 4670487 |
| `payment_ts` | timestamp | 2026-02-18 12:22:07.691 |
| `hours` | integer | 10 |
| `price_per_hour_usd` | decimal | 22.5 |

### `raw_lessons.csv` (~53,000 rows)

| Column | Type | Example |
|---|---|---|
| `lesson_id` | integer | 5014124 |
| `student_id` | integer | 4463246 |
| `booking_ts` | timestamp | 2025-03-20 19:43:36.624 |
| `hours_booked` | decimal | 0.5, 1.0, 1.5, 2.0 |

## Dataset characteristics

- **Time range**: ~13 months ending 2026-04-17 (the AS_OF_DATE)
- **Open cycles at AS_OF_DATE**: ~850 payments are inside their 28-day window
- **Closed cycles**: ~8,800 payments have completed cycles with known breakage
- **Cycle rhythm**: Every student's subsequent payments are exactly 28 days after their previous payment (same hour/minute/second)