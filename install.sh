#!/usr/bin/env bash
#
# AidaPlatformDB installer. Stands a platform up from its repositories:
#
#   ./install.sh database     the shared MySQL and NocoDB (this host)
#   ./install.sh apps         Identity, AidaAdmin, AidaAgent and the Echo environment
#   ./install.sh officepulse  OfficePulseAidaIntegration on the PBX host
#   ./install.sh all          database, then apps, on one host
#
# Every value it needs is a flag or a prompt; nothing is guessed about the
# domain. Re-running is safe: existing .env values, rows with a value and
# accounts are kept. README.md describes each phase.
set -euo pipefail

SELF=$(readlink -f "$0")
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)
GIT_BASE=${AIDA_GIT_BASE:-https://github.com/localsplash}

BRANCH=main
DIR=/opt/local
YES=0
DRY=0
NO_DEPLOY=0
PARENT_DOMAIN=${PARENT_DOMAIN:-}
ENVIRONMENT_NAME=${ENVIRONMENT_NAME:-}
NOCODB_BASE_URL=${NOCODB_BASE_URL:-}
NOCODB_TOKEN=${NOCODB_TOKEN:-}
TRUSTED_CIDR=${TRUSTED_CIDR:-}
DB_HOST=${DB_HOST:-}
MYSQL_PUBLISH=${MYSQL_PUBLISH:-}
MYSQL_ADMIN_PASSWORD=${MYSQL_ADMIN_PASSWORD:-}
TOKEN_IDENTITY=${TOKEN_IDENTITY:-}
TOKEN_AIDA_ADMIN=${TOKEN_AIDA_ADMIN:-}
TOKEN_AIDA_AGENT=${TOKEN_AIDA_AGENT:-}
TOKEN_ECHO_WEB=${TOKEN_ECHO_WEB:-}
TOKEN_ECHO_SERVICE=${TOKEN_ECHO_SERVICE:-}
TOKEN_OFFICEPULSE=${TOKEN_OFFICEPULSE:-}

# The store, found by name. PLATFORMCONFIG_BASE exists for the installer's
# own tests against a throwaway base; deployments never set it.
BASE_NAME=${PLATFORMCONFIG_BASE:-PlatformConfig}
TABLE_NAME=${PLATFORMCONFIG_TABLE:-cfg_tbl_Setting}
NOCODB_API_URL=""   # where this host reaches NocoDB's API; defaults to NOCODB_BASE_URL
TABLE_ID=""
ROWS_JSON=""

PROXY_NETWORK=npm_network
PLATFORM_NETWORK=platform-local
PLATFORM_SUBNET=192.168.112.0/20
ECHO_NETWORK=echo-local
ECHO_SUBNET=10.247.23.0/24

usage() {
  sed -n '3,12p' "$SELF" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options
  --branch NAME            git branch for every repository (default main)
  --dir PATH               install root (default /opt/local)
  --parent-domain X.TLD    the domain this platform is deployed under
  --environment-name NAME  dev | staging | prod
  --nocodb-base-url URL    https://nocodb.X.TLD (default derived from --parent-domain)
  --nocodb-token TOKEN     installer token for seeding rows (apps: defaults to the identity token)
  --trusted-cidr LIST      the *\trustedCIDR row (default: the Docker subnets and this host)
  --db-host HOST           MySQL as the apps reach it (default: platform-mysql-local here, else lsdb.X.TLD)
  --mysql-admin-password P MySQL root password (default: read from this folder's .env)
  --mysql-publish ADDR     database: where MySQL listens, e.g. 0.0.0.0:3306 (default 127.0.0.1:3306)
  --token-identity, --token-aida-admin, --token-aida-agent, --token-echo-web,
  --token-echo-service, --token-officepulse   per-application NocoDB API tokens
  --yes                    never prompt; a missing value is an error
  --no-deploy              clone, write .env files, create accounts and rows, but do not build or start
  --dry-run                print what would happen and change nothing
  -h, --help
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { echo "install: $*" >&2; exit 2; }
run()  { if (( DRY )); then echo "    + $*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
secret() { openssl rand -hex 32; }

# ask VAR --flag "prompt" [default]: keeps a value already given, otherwise
# prompts (or takes the default under --yes / without a terminal).
ask() {
  local var=$1 flag=$2 prompt=$3 default=${4:-} value
  [ -n "${!var}" ] && return 0
  if (( YES )) || [ ! -t 0 ]; then
    [ -n "$default" ] && { printf -v "$var" '%s' "$default"; return 0; }
    die "$prompt: give it with $flag"
  fi
  read -r -p "$prompt${default:+ [$default]}: " value
  printf -v "$var" '%s' "${value:-$default}"
  [ -n "${!var}" ] || die "$prompt is required"
}

prereqs() {
  local missing=()
  for tool in "$@"; do have "$tool" || missing+=("$tool"); done
  if [ "${#missing[@]}" -gt 0 ]; then die "missing on this host: ${missing[*]}"; fi
  if printf '%s\n' "$@" | grep -qx docker; then
    docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
  fi
}

# ── Docker objects ───────────────────────────────────────────────────────────

ensure_network() { # NAME [SUBNET] [--internal]
  local name=$1 subnet=${2:-} internal=${3:-}
  if docker network inspect "$name" >/dev/null 2>&1; then note "network $name exists"; return; fi
  run docker network create ${subnet:+--subnet "$subnet"} ${internal:+"$internal"} "$name"
}

ensure_proxy_network() {
  if docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then note "network $PROXY_NETWORK exists"; return; fi
  note "no $PROXY_NETWORK network: creating it. The reverse proxy must join it to reach the containers."
  run docker network create "$PROXY_NETWORK"
}

ensure_volume() {
  if docker volume inspect "$1" >/dev/null 2>&1; then note "volume $1 exists"; return; fi
  run docker volume create "$1"
}

# ── .env files ───────────────────────────────────────────────────────────────

# env_set FILE KEY VALUE: sets KEY when the file has no non-blank value for it.
env_set() {
  local file=$1 key=$2 value=$3
  if (( DRY )); then echo "    + $file: $key=$([[ $key =~ (PASSWORD|SECRET|TOKEN) ]] && echo '<secret>' || echo "$value")"; return; fi
  [ -f "$file" ] || { : > "$file"; chmod 600 "$file"; }
  if grep -qE "^${key}=.+" "$file"; then return; fi
  sed -i "/^${key}=\s*$/d" "$file"
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

env_get() { # FILE KEY
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | sed -E "s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"
}

# ── Git ──────────────────────────────────────────────────────────────────────

clone_or_update() { # REPO DEST
  local repo=$1 dest=$2
  if [ -d "$dest/.git" ]; then
    note "$dest: pulling $BRANCH"
    run git -C "$dest" fetch --prune -q origin
    run git -C "$dest" checkout -q "$BRANCH"
    run git -C "$dest" pull -q --ff-only
  else
    note "$dest: cloning $repo@$BRANCH"
    run mkdir -p "$(dirname "$dest")"
    run git clone -q -b "$BRANCH" "$GIT_BASE/$repo.git" "$dest"
  fi
}

# export_stamp DIR: the build args every compose file reads.
export_stamp() {
  if (( DRY )) && [ ! -d "$1/.git" ]; then note "would stamp the build from $1"; return; fi
  local g=(git -c safe.directory='*' -C "$1")
  export BUILD_REVISION BUILD_REVISION_SHORT SOURCE_DATE_EPOCH BUILD_DIRTY
  BUILD_REVISION=$("${g[@]}" rev-parse HEAD)
  BUILD_REVISION_SHORT=$("${g[@]}" rev-parse --short=12 HEAD)
  SOURCE_DATE_EPOCH=$("${g[@]}" show -s --format=%ct HEAD)
  if [ -n "$("${g[@]}" status --porcelain)" ]; then BUILD_DIRTY=true; else BUILD_DIRTY=false; fi
}

# ── NocoDB / PlatformConfig ──────────────────────────────────────────────────

nc() { # PATH [curl args]
  local path=$1; shift
  curl -fsS -H "xc-token: $NOCODB_TOKEN" -H 'Content-Type: application/json' "${NOCODB_API_URL:-$NOCODB_BASE_URL}$path" "$@"
}

ensure_platformconfig() {
  [ -n "$NOCODB_TOKEN" ] || die "a NocoDB API token is required to reach $BASE_NAME"
  if (( DRY )); then note "would find or create $BASE_NAME/$TABLE_NAME at ${NOCODB_API_URL:-$NOCODB_BASE_URL}"; TABLE_ID=dry; ROWS_JSON='[]'; return; fi
  local bases base_id tables
  bases=$(nc /api/v2/meta/bases) || die "NocoDB at ${NOCODB_API_URL:-$NOCODB_BASE_URL} did not answer or rejected the token"
  base_id=$(jq -r --arg t "$BASE_NAME" '[.list[] | select(.title==$t)] | if length==1 then .[0].id elif length==0 then "" else "dup" end' <<<"$bases")
  [ "$base_id" != dup ] && [ "$base_id" != null ] || die "more than one NocoDB base is named $BASE_NAME"
  # A base created through the API is not visible to the API token afterwards
  # (NocoDB grants base access to the token's user only when the base is
  # created in the UI), so the base itself is the one thing created by hand.
  [ -n "$base_id" ] || die "no NocoDB base named $BASE_NAME: create it in the NocoDB UI (Bases -> New base) and re-run"
  note "base $BASE_NAME found"
  tables=$(nc "/api/v2/meta/bases/$base_id/tables")
  TABLE_ID=$(jq -r --arg t "$TABLE_NAME" '[.list[] | select(.title==$t)] | if length==1 then .[0].id elif length==0 then "" else "dup" end' <<<"$tables")
  [ "$TABLE_ID" != dup ] || die "more than one $TABLE_NAME table in $BASE_NAME"
  if [ -z "$TABLE_ID" ]; then
    note "creating table $TABLE_NAME"
    if (( DRY )); then TABLE_ID=dry; return; fi
    # The same columns Identity's bootstrap creates, so either may go first.
    TABLE_ID=$(nc "/api/v2/meta/bases/$base_id/tables" -X POST --data "$(jq -n --arg t "$TABLE_NAME" '{
      title: $t, table_name: $t,
      columns: [
        {column_name:"id", title:"Id", uidt:"ID", pk:true},
        {column_name:"app", title:"app", uidt:"SingleLineText"},
        {column_name:"settingKey", title:"settingKey", uidt:"SingleLineText"},
        {column_name:"settingValue", title:"settingValue", uidt:"LongText"},
        {column_name:"description", title:"description", uidt:"LongText"},
        {column_name:"bSecret", title:"bSecret", uidt:"Checkbox"},
        {column_name:"dtCreated", title:"dtCreated", uidt:"CreatedTime"},
        {column_name:"dtUpdated", title:"dtUpdated", uidt:"LastModifiedTime"}
      ]}')" | jq -r .id)
  else
    note "table $TABLE_NAME found"
  fi
  rows_load
}

rows_load() {
  ROWS_JSON='[]'
  [ "$TABLE_ID" = dry ] && return
  local offset=0 page
  local count
  while :; do
    page=$(nc "/api/v2/tables/$TABLE_ID/records?limit=200&offset=$offset") || die "could not read $TABLE_NAME (table $TABLE_ID)"
    count=$(jq '.list | length' <<<"$page") || die "$TABLE_NAME returned an invalid record list"
    ROWS_JSON=$(jq -s '.[0] + .[1].list' <(echo "$ROWS_JSON") <(echo "$page"))
    [ "$count" -lt 200 ] && break
    offset=$((offset + 200))
  done
}

row_get() { # APP KEY -> value ('' when absent or blank)
  jq -r --arg a "$1" --arg k "$2" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].settingValue // "" | tostring' <<<"$ROWS_JSON" | sed 's/^null$//'
}

# row_ensure APP KEY VALUE SECRET(true|false) DESCRIPTION: creates the row, or
# fills a blank one; a row that already has a value is left alone.
row_ensure() {
  local app=$1 key=$2 value=$3 secret=$4 desc=$5 id shown
  shown=$value; [ "$secret" = true ] && shown='<secret>'
  id=$(jq -r --arg a "$app" --arg k "$key" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].Id // ""' <<<"$ROWS_JSON")
  if [ -n "$id" ] && [ -n "$(row_get "$app" "$key")" ]; then note "row $app/$key kept"; return; fi
  if [ -n "$id" ]; then
    note "row $app/$key filled in: $shown"
    (( DRY )) || nc "/api/v2/tables/$TABLE_ID/records" -X PATCH --data "$(jq -n --argjson id "$id" --arg v "$value" '[{Id:$id, settingValue:$v}]')" >/dev/null
  else
    note "row $app/$key created: $shown"
    (( DRY )) || nc "/api/v2/tables/$TABLE_ID/records" -X POST --data "$(jq -n --arg a "$app" --arg k "$key" --arg v "$value" --argjson s "$secret" --arg d "$desc" '{app:$a, settingKey:$k, settingValue:$v, bSecret:$s, description:$d}')" >/dev/null
  fi
  (( DRY )) || rows_load
}

# row_default APP KEY DEFAULT SECRET DESCRIPTION: the effective value ends up
# in ROW_VALUE (not echoed: a command substitution would run this in a subshell
# and the parent would never see the row it created).
ROW_VALUE=""
row_default() {
  ROW_VALUE=$(row_get "$1" "$2")
  if [ -n "$ROW_VALUE" ]; then note "row $1/$2 kept"; return; fi
  row_ensure "$@"
  ROW_VALUE=$3
}

default_trusted_cidr() {
  local host_ip
  host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
  printf '%s,%s%s' "$PLATFORM_SUBNET" "$ECHO_SUBNET" "${host_ip:+,$host_ip/32}"
}

proxy_subnet() {
  docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$PROXY_NETWORK" 2>/dev/null || true
}

wait_for() { # DESCRIPTION SECONDS CMD...
  local what=$1 seconds=$2; shift 2
  (( DRY )) && return 0
  local i; for ((i = 0; i < seconds; i += 3)); do "$@" >/dev/null 2>&1 && return 0; sleep 3; done
  die "$what did not become ready in ${seconds}s"
}

compose_up() { # DIR
  export_stamp "$1"
  run docker compose --project-directory "$1" up -d --build
}

# ── Phase a: the database host ───────────────────────────────────────────────

phase_database() {
  log "Database host: MySQL and NocoDB from $SELF_DIR"
  prereqs docker git jq openssl curl
  ask PARENT_DOMAIN --parent-domain "Apex domain this platform lives under (X.TLD)"
  ask ENVIRONMENT_NAME --environment-name "Environment name (dev, staging, prod)" dev
  NOCODB_BASE_URL=${NOCODB_BASE_URL:-https://nocodb.$PARENT_DOMAIN}

  log "External networks and volumes"
  ensure_proxy_network
  ensure_network "$PLATFORM_NETWORK" "$PLATFORM_SUBNET"
  ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET" --internal
  ensure_volume platform-mysql-data
  ensure_volume platform-nocodb-data

  log "$SELF_DIR/.env"
  env_set "$SELF_DIR/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD "$(secret)"
  env_set "$SELF_DIR/.env" NC_AUTH_JWT_SECRET "$(secret)"
  [ -n "$MYSQL_PUBLISH" ] && env_set "$SELF_DIR/.env" MYSQL_PUBLISH "$MYSQL_PUBLISH"

  log "Starting MySQL and NocoDB"
  run docker compose --project-directory "$SELF_DIR" up -d
  wait_for "MySQL" 180 sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" platform-mysql-local)" = healthy ]'
  wait_for "NocoDB" 180 curl -fsS -o /dev/null http://127.0.0.1:18087/
  NOCODB_API_URL=http://127.0.0.1:18087

  log "Claim NocoDB"
  note "Route $NOCODB_BASE_URL at the reverse proxy to platform-nocodb-local:8080 on $PROXY_NETWORK,"
  note "open it, and sign up: the first account becomes NocoDB's super admin. Then:"
  note "  1. create a base named $BASE_NAME (Bases -> New base); the API cannot do this for you,"
  note "  2. create one API token per application (Account -> Tokens): installer, identity,"
  note "     aida-admin, aida-agent, echo-web, echo-service, and officepulse if you run it."
  if [ -z "$NOCODB_TOKEN" ] && { (( YES )) || [ ! -t 0 ]; }; then
    note "No --nocodb-token: skipping the PlatformConfig rows. Re-run with a token to seed them."
  else
    ask NOCODB_TOKEN --nocodb-token "The installer token"
    log "PlatformConfig"
    ensure_platformconfig
    ask TRUSTED_CIDR --trusted-cidr "trustedCIDR: the networks the platform's servers sit on" "$(default_trusted_cidr)"
    row_ensure '*' PARENT_DOMAIN "$PARENT_DOMAIN" false "Apex domain (X.TLD) every application lives under; apps derive https://<app>.<PARENT_DOMAIN> from it."
    row_ensure '*' ENVIRONMENT_NAME "$ENVIRONMENT_NAME" false "dev, staging or prod; shown by the applications so nobody mistakes one environment for another."
    row_ensure '*' trustedCIDR "$TRUSTED_CIDR" false "IPv4 CIDRs (comma-separated) the platform's servers sit on. One value for the whole platform: every application admits server-to-server callers by it."
  fi

  log "Done. Two things only you can do:"
  note "1. NocoDB holds every secret the platform has. Block $NOCODB_BASE_URL from the public"
  note "   internet at the reverse proxy, or allow only trustedCIDR."
  note "2. Keep $SELF_DIR/.env (mode 600): it is the MySQL root password."
  [ -n "$MYSQL_PUBLISH" ] && note "3. MySQL listens on $MYSQL_PUBLISH: firewall it to trustedCIDR."
  return 0
}

# ── Phase b: the application host ────────────────────────────────────────────

phase_apps() {
  log "Application host: Identity, AidaAdmin, AidaAgent and the Echo environment under $DIR"
  prereqs docker git jq openssl curl
  ask PARENT_DOMAIN --parent-domain "Apex domain this platform lives under (X.TLD)"
  ask ENVIRONMENT_NAME --environment-name "Environment name (dev, staging, prod)" dev
  NOCODB_BASE_URL=${NOCODB_BASE_URL:-https://nocodb.$PARENT_DOMAIN}
  ask TOKEN_IDENTITY --token-identity "NocoDB API token for identity"
  ask TOKEN_AIDA_ADMIN --token-aida-admin "NocoDB API token for aida-admin"
  ask TOKEN_AIDA_AGENT --token-aida-agent "NocoDB API token for aida-agent"
  ask TOKEN_ECHO_WEB --token-echo-web "NocoDB API token for echo-web"
  ask TOKEN_ECHO_SERVICE --token-echo-service "NocoDB API token for echo-service"
  NOCODB_TOKEN=${NOCODB_TOKEN:-$TOKEN_IDENTITY}

  local db_local=0
  if docker container inspect platform-mysql-local >/dev/null 2>&1; then db_local=1; fi
  if (( db_local )); then
    ask DB_HOST --db-host "MySQL host as the applications reach it" platform-mysql-local
    MYSQL_ADMIN_PASSWORD=${MYSQL_ADMIN_PASSWORD:-$(env_get "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD)}
  else
    ask DB_HOST --db-host "MySQL host as the applications reach it" "lsdb.$PARENT_DOMAIN"
  fi
  ask MYSQL_ADMIN_PASSWORD --mysql-admin-password "MySQL root password on $DB_HOST"

  log "External networks and volumes"
  ensure_proxy_network
  ensure_network "$PLATFORM_NETWORK" "$PLATFORM_SUBNET"
  if (( db_local )); then ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET" --internal; else ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET"; fi
  ensure_volume aida-admin-assets
  ensure_volume echo-media-data
  ensure_volume echo-service-logs

  log "Checkouts ($BRANCH)"
  [ "$SELF_DIR" = "$DIR/AidaPlatformDB" ] || clone_or_update AidaPlatformDB "$DIR/AidaPlatformDB"
  clone_or_update identity "$DIR/identity"
  clone_or_update AidaAdmin "$DIR/aida/AidaAdmin"
  clone_or_update AidaAgent "$DIR/aida/AidaAgent"
  clone_or_update EchoWeb "$DIR/echo/EchoWeb"
  clone_or_update EchoService "$DIR/echo/EchoService"
  clone_or_update EchoMedia "$DIR/echo/EchoMedia"
  local f
  for f in compose.yaml web.host.yaml service.host.yaml deploy.sh; do
    if [ ! -e "$DIR/echo/$f" ]; then
      note "echo/$f from EchoWeb/deploy/environment"
      run cp "$DIR/echo/EchoWeb/deploy/environment/$f" "$DIR/echo/$f"
    fi
  done

  log ".env files (existing values are kept)"
  env_set "$DIR/identity/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$DIR/identity/.env" NOCODB_API_TOKEN "$TOKEN_IDENTITY"
  env_set "$DIR/aida/AidaAdmin/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$DIR/aida/AidaAdmin/.env" NOCODB_API_TOKEN "$TOKEN_AIDA_ADMIN"
  env_set "$DIR/aida/AidaAgent/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$DIR/aida/AidaAgent/.env" NOCODB_API_TOKEN "$TOKEN_AIDA_AGENT"
  local echo_env="$DIR/echo/.env"
  env_set "$echo_env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$echo_env" ECHO_WEB_NOCODB_API_TOKEN "$TOKEN_ECHO_WEB"
  env_set "$echo_env" ECHO_SERVICE_NOCODB_API_TOKEN "$TOKEN_ECHO_SERVICE"
  env_set "$echo_env" ECHO_NETWORK "$ECHO_NETWORK"
  env_set "$echo_env" ECHO_MEDIA_VOLUME echo-media-data
  env_set "$echo_env" ECHO_SERVICE_LOGS_VOLUME echo-service-logs
  env_set "$echo_env" ECHO_DB_HOST "$DB_HOST"
  env_set "$echo_env" MYSQL_ADMIN_PASSWORD "$MYSQL_ADMIN_PASSWORD"
  env_set "$echo_env" ECHO_WEB_DB_PASSWORD "$(secret)"
  env_set "$echo_env" ECHO_SERVICE_DB_PASSWORD "$(secret)"
  env_set "$echo_env" ECHO_WEB_TAG '${ENVIRONMENT_NAME}-${ECHO_WEB_SHORT:-${BUILD_REVISION_SHORT-local}}'
  env_set "$echo_env" ECHO_SERVICE_TAG '${ENVIRONMENT_NAME}-${ECHO_SERVICE_SHORT:-${BUILD_REVISION_SHORT-local}}'
  env_set "$echo_env" ECHO_MEDIA_TAG '${ENVIRONMENT_NAME}-${ECHO_MEDIA_SHORT:-${BUILD_REVISION_SHORT-local}}'
  env_set "$echo_env" ENVIRONMENT_NAME "$ENVIRONMENT_NAME"

  log "PlatformConfig rows"
  ensure_platformconfig
  row_ensure '*' PARENT_DOMAIN "$PARENT_DOMAIN" false "Apex domain (X.TLD) every application lives under; apps derive https://<app>.<PARENT_DOMAIN> from it."
  row_ensure '*' ENVIRONMENT_NAME "$ENVIRONMENT_NAME" false "dev, staging or prod; shown by the applications so nobody mistakes one environment for another."
  local current_cidr; current_cidr=$(row_get '*' trustedCIDR)
  ask TRUSTED_CIDR --trusted-cidr "trustedCIDR: the networks the platform's servers sit on" "${current_cidr:-$(default_trusted_cidr)}"
  row_ensure '*' trustedCIDR "$TRUSTED_CIDR" false "IPv4 CIDRs (comma-separated) the platform's servers sit on. One value for the whole platform: every application admits server-to-server callers by it."

  # One shared secret for redeeming Identity handoff codes; Identity mints it if absent.
  local client_secret identity_db_password aida_admin_password aida_admin_url
  row_default identity IDENTITY_CLIENT_SECRET "$(secret)" true "Shared secret applications present at POST /api/token while IDENTITY_APP_AUTH_MODE is secret or dual."
  client_secret=$ROW_VALUE
  row_ensure echo-web IDENTITY_CLIENT_SECRET "$client_secret" true "Shared secret EchoWeb presents to Identity /api/token; same value as identity/IDENTITY_CLIENT_SECRET."
  row_ensure aida-admin ID_CLIENT_SECRET "$client_secret" true "Shared secret AidaAdmin presents to Identity /api/token; same value as identity/IDENTITY_CLIENT_SECRET."

  # Database coordinates. A host the apps can derive (lsdb.<PARENT_DOMAIN>) needs no row.
  if [ "$DB_HOST" != "lsdb.$PARENT_DOMAIN" ]; then
    row_ensure identity DB_HOST "$DB_HOST" false "MySQL host holding platform_db. Unset derives lsdb.<PARENT_DOMAIN>."
    row_ensure echo DB_HOST "$DB_HOST" false "Echo application database host. Unset derives lsdb.<PARENT_DOMAIN>."
  fi
  row_ensure identity DB_USER identity false "MySQL user for platform_db; created by identity/scripts/db-users.sh."
  row_ensure identity DB_NAME platform_db false "Identity's database."
  row_default identity DB_PASSWORD "$(secret)" true "Password for DB_USER; the same value identity/scripts/db-users.sh sets."
  identity_db_password=$ROW_VALUE
  row_ensure echo DB_NAME echo_db false "Echo application database; restart the pool after changes."
  row_ensure echo-web DB_USER echo_web false "EchoWeb's read-only account, created by AidaPlatformDB/echo's db-users job."
  row_ensure echo-web DB_PASSWORD "$(env_get "$echo_env" ECHO_WEB_DB_PASSWORD)" true "Same value as ECHO_WEB_DB_PASSWORD in the Echo environment's .env."
  row_ensure echo-service DB_USER echo_service false "EchoService's account, created by AidaPlatformDB/echo's db-users job."
  row_ensure echo-service DB_PASSWORD "$(env_get "$echo_env" ECHO_SERVICE_DB_PASSWORD)" true "Same value as ECHO_SERVICE_DB_PASSWORD in the Echo environment's .env."
  aida_admin_password=$(secret)
  row_default aida-admin AIDA_ADMIN_DATABASE_URL "mysql://aida_admin_app:$aida_admin_password@$DB_HOST:3306/aida_admin_db" true "AidaAdmin's own store (OAuth state, receipts, audit); the account is created by AidaAdmin/scripts/db-users.sh from this URL."
  aida_admin_url=$ROW_VALUE

  # Everything else the applications need before their first start.
  local carrier
  for carrier in BANDWIDTH TYCHRON; do
    row_ensure echo-service "${carrier}_WEBHOOK_BASIC_USER" "echo-webhook-$ENVIRONMENT_NAME" false "$carrier webhook Basic Auth username; callers inside trustedCIDR are admitted without it."
    row_ensure echo-service "${carrier}_WEBHOOK_BASIC_PASS" "$(secret)" true "$carrier webhook Basic Auth password; takes effect within 30 seconds."
  done
  row_ensure aida-admin SESSION_SECRET "$(secret)" true "Cookie-signing secret for AidaAdmin's own browser sessions."
  row_ensure aida-admin PUBLIC_BASE_URL "https://aida-admin.$PARENT_DOMAIN" false "Public origin of AidaAdmin; builds the OAuth redirect_uri and the /id/events webhook URL."
  row_ensure aida-admin ID_BASE_URL "https://identity.$PARENT_DOMAIN" false "Identity's public origin as AidaAdmin calls it. Scoped to aida-admin on purpose: OfficePulse refuses this key in *, aida and officepulse."
  row_ensure aida-admin ID_TRUSTED_PROXY_CIDRS "$(proxy_subnet)" false "Reverse proxies whose X-Forwarded-For AidaAdmin believes (the proxy's Docker network)."
  row_ensure aida OFFICEPULSE_API_BASE_URL "https://officepulse-api.$PARENT_DOMAIN" false "OfficePulse's private API origin: AidaAdmin's orchestration calls and AidaAgent's call bootstrap."
  row_ensure aida AIDA_ROUTE_TOKEN_ATTRIBUTE sip.aidaRouteToken false "LiveKit SIP trunk attribute the X-Aida-Route-Token header is mapped to; read by OfficePulse and AidaAgent."
  row_ensure aida LIVEKIT_AGENT_NAME "aida-prime-$ENVIRONMENT_NAME" false "Agent name AidaAgent registers under and OfficePulse dispatches to. Only one worker may hold a name in the LiveKit project."
  row_ensure aida-agent AIDA_STT_MODEL deepgram/nova-3-general false "LiveKit Inference speech-to-text model."
  row_ensure aida-agent AIDA_LLM_MODEL google/gemma-4-31b-it false "LiveKit Inference LLM."
  row_ensure aida-agent AIDA_TTS_MODEL deepgram/aura-2 false "LiveKit Inference text-to-speech model."
  row_ensure aida-agent AIDA_TTS_VOICE asteria false "Voice for AIDA_TTS_MODEL."

  log "MySQL accounts on $DB_HOST"
  run docker run --rm --network "$PLATFORM_NETWORK" -v "$DIR/identity/scripts:/scripts:ro" \
    -e DB_HOST="$DB_HOST" -e DB_PASSWORD="$identity_db_password" -e MYSQL_ADMIN_PASSWORD="$MYSQL_ADMIN_PASSWORD" \
    mysql:8.4 bash /scripts/db-users.sh
  run docker run --rm --network "$PLATFORM_NETWORK" -v "$DIR/aida/AidaAdmin/scripts:/scripts:ro" \
    -e AIDA_ADMIN_DATABASE_URL="$aida_admin_url" -e MYSQL_ADMIN_PASSWORD="$MYSQL_ADMIN_PASSWORD" \
    mysql:8.4 bash /scripts/db-users.sh
  note "echo_web and echo_service are created by the Echo environment's own jobs at deploy"

  if (( NO_DEPLOY )); then log "--no-deploy: stopping before build and start"; else
    log "Building and starting"
    compose_up "$DIR/identity"
    compose_up "$DIR/aida/AidaAdmin"
    compose_up "$DIR/aida/AidaAgent"
    run "$DIR/echo/deploy.sh"
  fi

  log "Next, at the reverse proxy on $PROXY_NETWORK (TLS for *.$PARENT_DOMAIN):"
  note "identity.$PARENT_DOMAIN       -> identity:3200"
  note "aida-admin.$PARENT_DOMAIN     -> aida-admin:3001"
  note "echo.$PARENT_DOMAIN           -> echo-web:3160"
  note "echo-service.$PARENT_DOMAIN   -> echo-service:8080   (carrier webhooks only)"
  note "officepulse-api.$PARENT_DOMAIN -> the PBX host, port 8085"
  log "Still yours to fill in:"
  note "- https://identity.$PARENT_DOMAIN/setup claims Identity and takes the OAuth provider credentials."
  note "- aida/LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET: the LiveKit project (Identity's /admin edits any row)."
  note "- Carrier credentials in Echo's sms_tbl_CarrierApplication, and the webhook URLs registered at each carrier."
}

# ── Phase c: the PBX host ────────────────────────────────────────────────────

phase_officepulse() {
  log "PBX host: OfficePulseAidaIntegration under $DIR"
  prereqs git node npm rsync
  if ! systemctl is-active --quiet asterisk 2>/dev/null; then
    note "Asterisk is not running on this host (systemctl is-active asterisk). OfficePulse needs it; continuing anyway."
  fi
  ask PARENT_DOMAIN --parent-domain "Apex domain this platform lives under (X.TLD)"
  NOCODB_BASE_URL=${NOCODB_BASE_URL:-https://nocodb.$PARENT_DOMAIN}
  ask TOKEN_OFFICEPULSE --token-officepulse "NocoDB API token for officepulse"
  clone_or_update OfficePulseAidaIntegration "$DIR/OfficePulseAidaIntegration"
  local env_file=/etc/aida-integration/env
  log "$env_file"
  run mkdir -p "$(dirname "$env_file")"
  env_set "$env_file" NODE_ENV production
  env_set "$env_file" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$env_file" NOCODB_API_TOKEN "$TOKEN_OFFICEPULSE"
  note "Every other OfficePulse value is an officepulse/* row (its README lists them); the service reads them at start."
  if (( NO_DEPLOY )); then log "--no-deploy: stopping before its installer"; return 0; fi
  log "Running OfficePulse's own installer"
  run "$DIR/OfficePulseAidaIntegration/scripts/install.sh"
}

# ── Arguments ────────────────────────────────────────────────────────────────

# Test seam: `INSTALL_SOURCE_ONLY=1 source install.sh` loads the functions only.
if [ "${INSTALL_SOURCE_ONLY:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

PHASE=""
while [ $# -gt 0 ]; do
  case $1 in
    database|apps|officepulse|all) PHASE=$1 ;;
    --branch) BRANCH=$2; shift ;;
    --dir) DIR=$(readlink -f "$2"); shift ;;
    --parent-domain) PARENT_DOMAIN=$2; shift ;;
    --environment-name) ENVIRONMENT_NAME=$2; shift ;;
    --nocodb-base-url) NOCODB_BASE_URL=${2%/}; shift ;;
    --nocodb-token) NOCODB_TOKEN=$2; shift ;;
    --trusted-cidr) TRUSTED_CIDR=$2; shift ;;
    --db-host) DB_HOST=$2; shift ;;
    --mysql-admin-password) MYSQL_ADMIN_PASSWORD=$2; shift ;;
    --mysql-publish) MYSQL_PUBLISH=$2; shift ;;
    --token-identity) TOKEN_IDENTITY=$2; shift ;;
    --token-aida-admin) TOKEN_AIDA_ADMIN=$2; shift ;;
    --token-aida-agent) TOKEN_AIDA_AGENT=$2; shift ;;
    --token-echo-web) TOKEN_ECHO_WEB=$2; shift ;;
    --token-echo-service) TOKEN_ECHO_SERVICE=$2; shift ;;
    --token-officepulse) TOKEN_OFFICEPULSE=$2; shift ;;
    --yes) YES=1 ;;
    --no-deploy) NO_DEPLOY=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[ -n "$PHASE" ] || { usage; exit 2; }
case $ENVIRONMENT_NAME in ""|dev|staging|prod) ;; *) die "--environment-name must be dev, staging or prod" ;; esac
(( DRY )) && log "Dry run: nothing below is applied"

case $PHASE in
  database) phase_database ;;
  apps) phase_apps ;;
  officepulse) phase_officepulse ;;
  all) phase_database; phase_apps ;;
esac
