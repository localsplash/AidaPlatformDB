#!/usr/bin/env bash
#
# Create or update the MySQL users EchoWeb and EchoService connect as, with
# exactly the grants each needs. Idempotent: every run converges the grants,
# and a new password rotates it. Run it after scripts/migrate.sh, because the
# read-only grants name the routines that migrations create.
#
#   echo_web      SELECT on the schema. EchoWeb only reads (readiness and
#                 media ownership checks).
#   echo_service  SELECT on the schema, plus EXECUTE on the stored procedures,
#                 which are EchoService's whole write interface:
#                   ECHO_DB_ACCESS=read-write  every procedure (the default)
#                   ECHO_DB_ACCESS=read-only   only the *_GET procedures, so
#                                              nothing can be sent or changed
#
# The procedures run as their definer, so EXECUTE is all a writer needs;
# neither app gets INSERT, UPDATE or DELETE on a table.
#
# Run by an environment's operator with MySQL admin credentials, e.g. from a
# throwaway client on a network that reaches the database:
#
#   docker run --rm --network <network> -v "$PWD/scripts:/scripts:ro" \
#     -e DB_HOST=<mysql host> -e MYSQL_ADMIN_PASSWORD=… \
#     -e ECHO_WEB_DB_PASSWORD=… -e ECHO_SERVICE_DB_PASSWORD=… \
#     mysql:8.4 bash /scripts/db-users.sh
#
# or through the `echo-db-users` one-shot in compose.yaml. The passwords are
# the same values the environment gives EchoWeb and EchoService as
# DB_PASSWORD. Accounts are created for any host ('%'): which networks can
# reach MySQL is the environment's decision, not something to pin here.

set -euo pipefail

HOST="${DB_HOST:?DB_HOST: the MySQL host}"
PORT="${DB_PORT:-3306}"
DB="${DB_NAME:-echo_db}"
ADMIN="${MYSQL_ADMIN_USER:-root}"
: "${MYSQL_ADMIN_PASSWORD:?MYSQL_ADMIN_PASSWORD: password for $ADMIN}"
WEB_USER="${ECHO_WEB_DB_USER:-echo_web}"
SERVICE_USER="${ECHO_SERVICE_DB_USER:-echo_service}"
: "${ECHO_WEB_DB_PASSWORD:?ECHO_WEB_DB_PASSWORD: EchoWeb DB_PASSWORD}"
: "${ECHO_SERVICE_DB_PASSWORD:?ECHO_SERVICE_DB_PASSWORD: EchoService DB_PASSWORD}"
ACCESS="${ECHO_DB_ACCESS:-read-write}"

die() { echo "[db-users] $*" >&2; exit 2; }
# Names are interpolated into SQL, so they must be plain identifiers.
name() { [[ $1 =~ ^[A-Za-z0-9_]+$ ]] || die "not a plain identifier: $1"; printf '%s' "$1"; }
# A SQL string literal: backslashes and quotes escaped for the default sql_mode.
literal() { local s=${1//\\/\\\\}; printf "'%s'" "${s//\'/\'\'}"; }
# MYSQL_PWD keeps the admin password out of the process list; the SQL itself,
# including the app passwords, goes over stdin.
admin() {
  MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" command mysql --protocol=TCP -h "$HOST" -P "$PORT" \
    -u "$ADMIN" --batch --skip-column-names "$@"
}

DB=$(name "$DB"); WEB_USER=$(name "$WEB_USER"); SERVICE_USER=$(name "$SERVICE_USER")
# In a database-level GRANT, _ and % are wildcards: escape them so the grant
# names exactly this database (echo\_db). Routine-level grants take no
# wildcards and use the plain name.
DB_GRANT=${DB//_/\\_}
case "$ACCESS" in read-write|read-only) ;; *) die "ECHO_DB_ACCESS must be read-write or read-only" ;; esac

account() { # USER PASSWORD — create or rotate, then start from no privileges
  local who="'$1'@'%'"
  printf '%s\n' \
    "CREATE USER IF NOT EXISTS $who IDENTIFIED BY $(literal "$2");" \
    "ALTER USER $who IDENTIFIED BY $(literal "$2");" \
    "REVOKE ALL PRIVILEGES, GRANT OPTION FROM $who;"
}

if [ "$ACCESS" = read-write ]; then
  service_execute="GRANT EXECUTE ON \`$DB_GRANT\`.* TO '$SERVICE_USER'@'%';"
else
  service_execute=""
  while IFS= read -r routine; do
    service_execute+="GRANT EXECUTE ON PROCEDURE \`$DB\`.\`$(name "$routine")\` TO '$SERVICE_USER'@'%';"$'\n'
  done < <(admin -e "SELECT ROUTINE_NAME FROM information_schema.ROUTINES
                      WHERE ROUTINE_SCHEMA = '$DB' AND ROUTINE_TYPE = 'PROCEDURE'
                        AND ROUTINE_NAME LIKE '%\\_GET' ORDER BY ROUTINE_NAME")
  [ -n "$service_execute" ] || die "no *_GET procedures in $DB — run scripts/migrate.sh first"
fi

admin <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB\`;
$(account "$WEB_USER" "$ECHO_WEB_DB_PASSWORD")
GRANT SELECT ON \`$DB_GRANT\`.* TO '$WEB_USER'@'%';
$(account "$SERVICE_USER" "$ECHO_SERVICE_DB_PASSWORD")
GRANT SELECT ON \`$DB_GRANT\`.* TO '$SERVICE_USER'@'%';
$service_execute
SQL

echo "[db-users] $WEB_USER: SELECT on $DB"
if [ "$ACCESS" = read-write ]; then
  echo "[db-users] $SERVICE_USER: SELECT and EXECUTE (all procedures) on $DB"
else
  echo "[db-users] $SERVICE_USER: SELECT and EXECUTE on $(grep -c '^GRANT' <<<"$service_execute") *_GET procedure(s) on $DB (read-only)"
fi
