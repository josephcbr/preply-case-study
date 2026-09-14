---
name: dbt-sandbox-setup
description: Set up and run this dbt + Neon Postgres sandbox from a fresh clone - create the Python venv, install dbt-postgres, wire up the Neon connection, and load/build/test the data. Use whenever someone has just cloned this repo and wants dbt working locally against the shared database, or asks to "set up" or "run" this project.
---

# dbt sandbox setup

This repo is a standalone dbt project connected to a shared Neon Postgres
database (see the root `README.md` for background). Follow these steps in
order from the repo root. Stop and report back if a step fails - don't guess
past an error.

Always call the venv's `dbt` binary directly (`.venv/bin/dbt ...`) rather than
a bare `dbt`, in case the machine has some other `dbt` shell alias or function
defined elsewhere.

1. **Check Python version.** dbt-core does not yet support Python 3.14. Look
   for 3.11, 3.12, or 3.13, e.g. `python3.13 --version`. If none of those
   exist, tell the user to install one (e.g. `brew install python@3.13`)
   rather than falling back to an unsupported version.

2. **Create and activate a project-local venv, install dbt:**
   ```
   python3.13 -m venv .venv
   .venv/bin/pip install --upgrade pip
   .venv/bin/pip install dbt-postgres
   ```
   Skip this if `.venv/bin/dbt` already exists and works.

3. **Set up credentials.**
   - If `env.sh` already exists in the repo root, just read it (don't print
     the password back to the user) and move on.
   - If it doesn't exist, copy `env.example.sh` to `env.sh`, then ask the user
     for the Neon connection details: host, user, password, database (or the
     full `postgresql://user:password@host/dbname` connection string, which
     you can parse). Never invent placeholder credentials - ask if you don't
     have them. Fill the real values into `env.sh`.
   - `env.sh` is gitignored. Never commit it or print its contents into a
     shared/logged context beyond this local setup.

4. **Verify the connection:**
   ```
   source env.sh && .venv/bin/dbt debug
   ```
   If this fails, check whether the Neon project is paused/deleted and
   whether the credentials are current - don't retry blindly.

5. **Load the seed data:**
   ```
   source env.sh && .venv/bin/dbt seed
   ```
   Loads ~66k rows across 3 CSVs (students, payments, lessons). Takes about
   25 seconds. Skip if the tables are already seeded and the user just wants
   models rebuilt.

6. **Build the models:**
   ```
   source env.sh && .venv/bin/dbt run
   ```

7. **Run the tests:**
   ```
   source env.sh && .venv/bin/dbt test
   ```
   Should be 13/13 passing (uniqueness, not-null, referential integrity,
   accepted values on the staging models).

8. **Report back** what got built, seed row counts, and the test pass/fail
   summary. Remind the user `env.sh` holds real credentials and must stay
   untracked.
