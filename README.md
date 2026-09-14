# Preply breakage estimation — Analytics Engineer case study

A dbt project that models **subscription breakage** for Preply's tutoring
marketplace: for every payment, how many purchased hours will go unused
("breakage") by the end of its 28-day cycle — estimated daily while the
cycle is still open, replaced by the actual number once it closes. Includes
a Streamlit dashboard (`dashboard/`) on top of the resulting mart.

Built as a standalone sandbox against a free [Neon](https://neon.tech)
Postgres database — not tied to any company's Snowflake account, dbt Cloud
project, or GitHub org.

For the data model, design rationale, and everything else beyond "how do I
run this," see the design report (shared separately).

## Stack

- **Database:** Neon (serverless Postgres, free tier)
- **Transformation:** dbt-core + `dbt-postgres`, in its own Python virtualenv
- **Linting:** `sqlfluff` (dbt templater, Postgres dialect) — config in `.sqlfluff`
- **Dashboard:** Streamlit + Plotly, in its own virtualenv (`dashboard/`)

## Repo structure

```
seeds/            raw CSVs, loaded as tables via `dbt seed`
models/
  staging/        one clean, typed view per raw source
  core/           fct/dim tables
  marts/          student_breakage_daily — the dashboard-facing mart
macros/           custom generic test(s)
docs/             dataset schema + generation notes
dashboard/        Streamlit app reading directly from the same Neon database
dbt_project.yml   vars: current_date (fixed AS_OF_DATE), cycle_length (28)
profiles.yml      dbt connection profile — no secrets, reads from env vars
env.example.sh    template for the env vars profiles.yml needs
```

## Setup

**Using Claude Code?** Just open this repo and run `/dbt-sandbox-setup` — it
walks through everything below for you, including asking for the Neon
credentials if you don't have them yet.

Otherwise, requires Python 3.11–3.13 (dbt does not yet support 3.14):

```bash
git clone <this-repo-url>
cd preply-case-study

python3.13 -m venv .venv
source .venv/bin/activate
pip install dbt-postgres sqlfluff sqlfluff-templater-dbt

cp env.example.sh env.sh
# edit env.sh with the real Neon connection details (ask the project owner)
source env.sh

dbt debug   # confirms the connection to Neon works
dbt deps    # installs dbt_utils, dbt_date, codegen
dbt seed    # loads the 3 CSVs into Postgres (~66k rows, ~25s)
dbt build   # builds every model and runs all tests
```

Because everyone points at the **same** Neon database, you'll see the same
seeded data and the same models as anyone else working from this repo — no
need to load your own copy of the data. You can also connect with any
regular Postgres client (`psql`, TablePlus, DBeaver, etc.) using the same
connection string, to query the tables directly.

### Running the dashboard

```bash
cd dashboard
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp .streamlit/secrets.toml.example .streamlit/secrets.toml
# edit .streamlit/secrets.toml with the same Neon connection details

streamlit run app.py
```
Alternatively, you can access the deployed dashboard directly here: https://preply-case-study-p7exchpyctet47559hxtuz.streamlit.app/#breakage-and-revenue-pay-ops-dashboard
