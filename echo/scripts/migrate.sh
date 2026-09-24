#!/usr/bin/env bash
#
# Apply EchoDatabase's schema files to the database as it actually is.
#
# MySQL runs /docker-entrypoint-initdb.d ONLY when it initialises an empty data
# directory. Every numbered file added to EchoDatabase after the first `up` is
# therefore skipped in silence — which is how 009_settings.sql came to sit in
# the repo while a nine-day-old volume had no echo_tbl_Settings, and the
# applications failed at runtime with an error that looked nothing like the
# cause.
#
# So the same files are applied here, in order, against the running database,
# and each is recorded once it succeeds. This is a no-op on every start except
# the first that sees a new file.
#
# Moved here from EchoOrchestrator, unchanged apart from comments, so every
# environment upgrades its own database with the runner that ships with the
# schema. The ledger table and its rows are the same, so databases migrated
# by the old copy carry on where they left off. Run it with admin rights:
#
#   DB_HOST=… DB_USER=root MYSQL_PWD=… MYSQL_DATABASE=echo_db \
#     MIGRATIONS_DIR=init scripts/migrate.sh
#
# or through the `echo-migrate` one-shot in compose.yaml.
#
# The files are NOT idempotent and this does not pretend otherwise: 006/007/008
# are bare `ALTER TABLE ... ADD COLUMN`, and 001/003 seed lookup tables with
# bare INSERTs. Re-running any of them fails. The ledger is therefore the whole
# safety mechanism — each file runs exactly once, ever — which is also why an
# existing database has to be baselined rather than replayed. See below.

set -euo pipefail

HOST="${DB_HOST:-echo-database}"
USER="${DB_USER:-root}"
DB="${MYSQL_DATABASE:-echo_db}"
DIR="${MIGRATIONS_DIR:-/init}"

# MYSQL_PWD is read from the environment by the client, so the password never
# appears in the process list or in this script's trace output.
mysql() { command mysql --protocol=TCP -h "$HOST" -u "$USER" --batch --skip-column-names "$@"; }
sqlquote() { printf '%s' "${1//\'/\'\'}"; }

echo "[migrate] applying ${DIR}/*.sql to ${DB} on ${HOST}"

# compose gates us on the healthcheck, which proves the daemon is up — not that
# it is taking connections from here yet.
for attempt in $(seq 1 30); do
  if mysql -e 'SELECT 1' >/dev/null 2>&1; then break; fi
  if [ "$attempt" -eq 30 ]; then
    echo "[migrate] ${HOST} did not accept a connection after 30 tries" >&2
    exit 1
  fi
  sleep 2
done

mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB}\`"

shopt -s nullglob
files=("$DIR"/*.sql)
if [ ${#files[@]} -eq 0 ]; then
  echo "[migrate] no .sql files in ${DIR} — nothing to do"
  exit 0
fi
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort)); unset IFS

ledger_exists="$(mysql "$DB" -e "
  SELECT 1 FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = '$(sqlquote "$DB")' AND TABLE_NAME = 'echo_tbl_SchemaMigration'")"

mysql "$DB" -e "
  CREATE TABLE IF NOT EXISTS echo_tbl_SchemaMigration (
    sFile      VARCHAR(255) NOT NULL PRIMARY KEY,
    dtApplied  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    bBaselined TINYINT(1)  NOT NULL DEFAULT 0
  ) ENGINE=InnoDB"

# ── Baselining an existing database ──────────────────────────────────────────
#
# A database that already has the schema but no ledger predates this script.
# Its files were run by initdb, and re-running them would fail on the first
# duplicate column. But there is no way to ask MySQL *which* files ran — so
# every file present is recorded as applied, without being run, and the fact is
# logged rather than buried.
#
# The risk this accepts: a file added to the repo after that database was
# initialised, and never applied, gets marked as though it had been. That is
# why it says so loudly. It happens once per pre-existing deployment; every
# database created from here on gets a ledger from its first migrate.
if [ -z "$ledger_exists" ]; then
  has_schema="$(mysql "$DB" -e "
    SELECT 1 FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = '$(sqlquote "$DB")' AND TABLE_NAME = 'sms_tbl_Message'")"
  if [ -n "$has_schema" ]; then
    echo "[migrate] ================================================================"
    echo "[migrate] Existing database with no migration ledger."
    echo "[migrate] Recording all ${#files[@]} current file(s) as already applied,"
    echo "[migrate] WITHOUT running them — initdb ran them when this volume was"
    echo "[migrate] created, and they are not safe to re-run."
    echo "[migrate] If a file was added to EchoDatabase after this database was"
    echo "[migrate] created and never applied by hand, it is now marked as though"
    echo "[migrate] it had been. Check that before relying on this."
    echo "[migrate] ================================================================"
    for file in "${files[@]}"; do
      name="$(basename "$file")"
      mysql "$DB" -e "
        INSERT IGNORE INTO echo_tbl_SchemaMigration (sFile, bBaselined)
        VALUES ('$(sqlquote "$name")', 1)"
      echo "[migrate]   baselined ${name}"
    done
    echo "[migrate] baseline complete; future files will be applied normally"
    exit 0
  fi
  echo "[migrate] empty database — applying every file in order"
fi

applied=0
for file in "${files[@]}"; do
  name="$(basename "$file")"
  seen="$(mysql "$DB" -e "
    SELECT 1 FROM echo_tbl_SchemaMigration WHERE sFile = '$(sqlquote "$name")'")"
  [ -n "$seen" ] && continue

  echo "[migrate] applying ${name}"
  # No transaction: MySQL commits DDL implicitly, so wrapping this would
  # promise an atomicity that does not exist. A file that fails part way leaves
  # its own mess and is NOT recorded — fix it and run again.
  if ! mysql "$DB" < "$file"; then
    echo "[migrate] ${name} FAILED — not recorded; fix it and start again" >&2
    exit 1
  fi
  mysql "$DB" -e "INSERT INTO echo_tbl_SchemaMigration (sFile) VALUES ('$(sqlquote "$name")')"
  applied=$((applied + 1))
done

if [ "$applied" -eq 0 ]; then
  echo "[migrate] up to date (${#files[@]} file(s) already applied)"
else
  echo "[migrate] applied ${applied} new file(s)"
fi
