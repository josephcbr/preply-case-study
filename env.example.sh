# Copy this file to env.sh, fill in the real values, then run: source env.sh
# env.sh is gitignored — never commit real credentials.
# Ask the project owner for the actual Neon connection details.

export DBT_PROFILES_DIR="$(pwd)"

export PGHOST="ep-xxxxxxxx-pooler.c-2.us-east-2.aws.neon.tech"
export PGUSER="neondb_owner"
export PGPASSWORD="changeme"
export PGDATABASE="neondb"
export PGSCHEMA="sandbox"
