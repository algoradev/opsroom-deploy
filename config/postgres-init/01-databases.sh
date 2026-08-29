#!/usr/bin/env bash
# Creates the three logical databases + their roles.
# Runs once on first Postgres boot (docker-entrypoint-initdb.d convention).
#
# The app DB uses TWO roles deliberately:
#   * ${APP_DB_OWNER}  — owns the schema, used for migrations and admin
#     operations (bootstrap, reconcile). As owner, it's not subject to RLS
#     policies on tables it owns. RLS becomes an escape hatch for ops work.
#   * ${APP_DB_USER}   — non-owner, used for ordinary request handling.
#     RLS policies apply. If the API is ever exploited into running raw
#     SQL, it still can't cross tenant boundaries without setting the
#     session vars that the policies key off.
#
# Keycloak + OpenFGA each get their own single-role DB — they manage their
# own schemas and don't need this split.

set -euo pipefail

create_role() {
  local user="$1" password="$2"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
        CREATE ROLE ${user} LOGIN PASSWORD '${password}';
      END IF;
    END
    \$\$;
EOSQL
}

create_db() {
  local db="$1" owner="$2"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE DATABASE ${db} OWNER ${owner}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec

    REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
    GRANT CONNECT, TEMP ON DATABASE ${db} TO ${owner};
EOSQL
}

# --- app DB: owner + app user ---
create_role "$APP_DB_OWNER" "$APP_DB_OWNER_PASSWORD"
create_role "$APP_DB_USER"  "$APP_DB_PASSWORD"
create_db "$APP_DB_NAME" "$APP_DB_OWNER"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB_NAME" <<-EOSQL
  -- Non-owner needs to connect to the DB and see the schema namespace,
  -- but per-table grants are applied inside the Alembic migration (after
  -- the owner has created the tables).
  GRANT CONNECT ON DATABASE ${APP_DB_NAME} TO ${APP_DB_USER};
  GRANT USAGE ON SCHEMA public TO ${APP_DB_USER};
  ALTER SCHEMA public OWNER TO ${APP_DB_OWNER};
  -- Default privileges so tables created by the owner in the future also
  -- grant the expected CRUD privileges to the app user without a catch-up.
  ALTER DEFAULT PRIVILEGES FOR ROLE ${APP_DB_OWNER} IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_DB_USER};
  ALTER DEFAULT PRIVILEGES FOR ROLE ${APP_DB_OWNER} IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO ${APP_DB_USER};
EOSQL

# --- keycloak DB ---
create_role "$KC_DB_USER" "$KC_DB_PASSWORD"
create_db "$KC_DB_NAME" "$KC_DB_USER"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$KC_DB_NAME" <<-EOSQL
  GRANT ALL ON SCHEMA public TO ${KC_DB_USER};
  ALTER SCHEMA public OWNER TO ${KC_DB_USER};
EOSQL

# --- openfga DB ---
create_role "$FGA_DB_USER" "$FGA_DB_PASSWORD"
create_db "$FGA_DB_NAME" "$FGA_DB_USER"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$FGA_DB_NAME" <<-EOSQL
  GRANT ALL ON SCHEMA public TO ${FGA_DB_USER};
  ALTER SCHEMA public OWNER TO ${FGA_DB_USER};
EOSQL

echo "asunset: databases + roles provisioned"
