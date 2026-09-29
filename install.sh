#!/usr/bin/env bash
#
# AidaPlatformDB installer. Stands a platform up from its repositories:
#
#   ./install.sh database     the shared MySQL and NocoDB (this host)
#   ./install.sh apps         Identity, AidaAdmin, AidaAgent and the Echo environment
#   ./install.sh officepulse  OfficePulseAidaIntegration on the PBX host
#   ./install.sh all          database, then apps, on one host
#   ./install.sh migrate-data move MySQL's and NocoDB's data from the Docker
#                             volumes an older checkout used onto the host
#
# Run it from a checkout, or straight from GitHub on a fresh host:
#
#   curl -fsSL https://raw.githubusercontent.com/localsplash/AidaPlatformDB/main/install.sh \
#     | bash -s -- apps --branch main
#
# (it then clones this repository under --dir and continues from there).
# Every value it needs is a flag or a prompt; nothing is guessed about the
# domain. Re-running is safe: existing .env values, rows with a value and
# accounts are kept. README.md describes each phase.
set -euo pipefail

SELF=$(readlink -f "$0")
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)
GIT_BASE=${AIDA_GIT_BASE:-https://github.com/localsplash}

BRANCH=""
DIR=/opt
DIR_GIVEN=0
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
DATA_DIR=${DATA_DIR:-}
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
  sed -n '3,20p' "$SELF" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options
  --branch NAME            git branch for every repository (default: this checkout's branch, else main)
  --dir PATH               install root (default: this checkout's parent, else /opt)
  --parent-domain X.TLD    the domain this platform is deployed under
  --environment-name NAME  dev | staging | prod
  --nocodb-base-url URL    https://nocodb.X.TLD (default derived from --parent-domain)
  --nocodb-token TOKEN     installer token for seeding rows (apps: defaults to the identity token)
  --trusted-cidr LIST      the *\trustedCIDR row (default: the Docker subnets and this host)
  --db-host HOST           MySQL as the apps reach it (default: platform-mysql-local here, else lsdb.X.TLD)
  --mysql-admin-password P MySQL root password (default: read from this folder's .env)
  --mysql-publish ADDR     database: where MySQL listens, e.g. 0.0.0.0:3306 (default 127.0.0.1:3306)
  --data-dir PATH          database: host directory for MySQL's and NocoDB's data (default /var/lib/aidaplatformdb)
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
# Dry runs print the command with secret-looking values masked.
run()  { if (( DRY )); then printf '    + %s\n' "$(printf '%s ' "$@" | sed -E "s/((PASSWORD|SECRET|TOKEN|PWD)=)[^ ]*/\\1<secret>/g; s/(IDENTIFIED BY ')[^']*'/\\1<secret>'/g; s#(mysql://[^:]+:)[^@]*@#\\1<secret>@#g")"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
secret() { openssl rand -hex 32; }

# ask VAR --flag "prompt" [default]: keeps a value already given, otherwise
# prompts on the terminal (or takes the default under --yes / without one).
# Prompts read /dev/tty, so `curl | bash` — whose stdin is the script — works.
# A password, secret or token is typed without echo: it must not end up in
# the terminal's scrollback or in a pasted transcript.
ask() {
  local var=$1 flag=$2 prompt=$3 default=${4:-} value
  [ -n "${!var}" ] && return 0
  if (( YES )) || ! { : < /dev/tty; } 2>/dev/null; then
    [ -n "$default" ] && { printf -v "$var" '%s' "$default"; return 0; }
    die "$prompt: give it with $flag"
  fi
  if [[ $var =~ (PASSWORD|SECRET|TOKEN) ]]; then
    read -rs -p "$prompt (not echoed): " value < /dev/tty; echo > /dev/tty
  else
    read -r -p "$prompt${default:+ [$default]}: " value < /dev/tty
  fi
  printf -v "$var" '%s' "${value:-$default}"
  [ -n "${!var}" ] || die "$prompt is required"
}

# The apex domain. Defaults to this host's own domain (its FQDN minus the host
# label), and anything that looks like a host name rather than an apex — the
# FQDN itself, more than two labels, or a first label such as www or one of the
# platform's own app names — is shown with the hostnames it would produce and
# has to be confirmed or corrected. --yes accepts it with the warning.
ask_parent_domain() {
  local fqdn short default answer label
  fqdn=$(hostname -f 2>/dev/null | tr 'A-Z' 'a-z' || true)
  short=${fqdn%%.*}
  default=$(hostname -d 2>/dev/null | tr 'A-Z' 'a-z' || true)
  while :; do
    ask PARENT_DOMAIN --parent-domain "Apex domain this platform lives under (X.TLD: the apps become identity.X.TLD, nocodb.X.TLD, ...)" "$default"
    PARENT_DOMAIN=$(printf '%s' "$PARENT_DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s/\.$//')
    if ! [[ $PARENT_DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
      (( YES )) && die "--parent-domain '$PARENT_DOMAIN' is not a domain name"
      note "'$PARENT_DOMAIN' is not a domain name (letters, digits, hyphens and dots, e.g. example.com)"
      PARENT_DOMAIN=""; continue
    fi
    label=${PARENT_DOMAIN%%.*}
    local suspicious=""
    if [ -n "$fqdn" ] && [ "$PARENT_DOMAIN" = "$fqdn" ]; then suspicious="it is this host's own name"
    elif [ "$label" = "$short" ]; then suspicious="it starts with this host's name"
    elif [[ " www identity nocodb echo echo-service aida-admin officepulse-api lsdb " == *" $label "* ]]; then suspicious="it starts with '$label', one of the platform's own hostnames"
    elif [ "$(tr -dc . <<<"$PARENT_DOMAIN" | wc -c)" -gt 1 ]; then suspicious="it has more than two labels"
    fi
    [ -z "$suspicious" ] && return 0
    note "'$PARENT_DOMAIN' looks like a host name rather than an apex domain ($suspicious)."
    note "With it, the platform's hostnames become identity.$PARENT_DOMAIN, nocodb.$PARENT_DOMAIN,"
    note "echo.$PARENT_DOMAIN, aida-admin.$PARENT_DOMAIN ...${default:+ This host is under $default.}"
    if (( YES )) || ! { : < /dev/tty; } 2>/dev/null; then note "Accepting it as given (--yes)."; return 0; fi
    read -r -p "Use '$PARENT_DOMAIN' as the apex domain anyway? [y/N] " answer < /dev/tty
    case ${answer,,} in y|yes) return 0 ;; esac
    PARENT_DOMAIN=""
  done
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

ensure_dir() {
  if [ -d "$1" ]; then note "directory $1 exists"; return; fi
  run mkdir -p "$1"
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

env_get() { # FILE KEY -> value, or nothing; never fails (set -e would end the script)
  [ -f "$1" ] || return 0
  { grep -E "^$2=" "$1" || true; } | tail -1 | cut -d= -f2- | sed -E "s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"
}

# ── Git ──────────────────────────────────────────────────────────────────────

# repo_branch REPO: --branch when the repository has it, else its default
# branch (a repository whose work has all been promoted may no longer have a
# dev branch, and one that has not been promoted may only have it).
repo_branch() {
  local repo=$1
  if git ls-remote --exit-code --heads "$GIT_BASE/$repo.git" "$BRANCH" >/dev/null 2>&1; then printf '%s' "$BRANCH"; return; fi
  local head; head=$(git ls-remote --symref "$GIT_BASE/$repo.git" HEAD 2>/dev/null | awk '$1=="ref:" && $3=="HEAD" {sub("refs/heads/", "", $2); print $2; exit}')
  note "$repo has no branch $BRANCH: using its default, ${head:-main}" >&2
  printf '%s' "${head:-main}"
}

clone_or_update() { # REPO DEST
  local repo=$1 dest=$2 branch; branch=$(repo_branch "$repo")
  if [ -d "$dest/.git" ]; then
    note "$dest: pulling $branch"
    run git -C "$dest" fetch --prune -q origin
    run git -C "$dest" checkout -q "$branch"
    run git -C "$dest" pull -q --ff-only
  else
    note "$dest: cloning $repo@$branch"
    run mkdir -p "$(dirname "$dest")"
    run git clone -q -b "$branch" "$GIT_BASE/$repo.git" "$dest"
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
  local bases base_id tables
  if (( DRY )); then
    # Read what is there so the dry run shows the real path; never create.
    TABLE_ID=dry; ROWS_JSON='[]'
    bases=$(nc /api/v2/meta/bases 2>/dev/null) || { note "would read $BASE_NAME/$TABLE_NAME at ${NOCODB_API_URL:-$NOCODB_BASE_URL} (not reachable now: assuming no rows)"; return; }
    base_id=$(jq -r --arg t "$BASE_NAME" '[.list[] | select(.title==$t)] | .[0].id // ""' <<<"$bases")
    [ -n "$base_id" ] || { note "would need base $BASE_NAME (not there yet)"; return; }
    tables=$(nc "/api/v2/meta/bases/$base_id/tables" 2>/dev/null) || return 0
    TABLE_ID=$(jq -r --arg t "$TABLE_NAME" '[.list[] | select(.title==$t)] | .[0].id // ""' <<<"$tables")
    [ -n "$TABLE_ID" ] || { note "would create table $TABLE_NAME"; TABLE_ID=dry; return; }
    rows_load; note "base $BASE_NAME and table $TABLE_NAME found ($(jq length <<<"$ROWS_JSON") rows)"; TABLE_ID=dry; return
  fi
  bases=$(nc /api/v2/meta/bases) || die "NocoDB at ${NOCODB_API_URL:-$NOCODB_BASE_URL} did not answer or rejected the token"
  base_id=$(jq -r --arg t "$BASE_NAME" '[.list[] | select(.title==$t)] | if length==1 then .[0].id elif length==0 then "" else "dup" end' <<<"$bases")
  [ "$base_id" != dup ] && [ "$base_id" != null ] || die "more than one NocoDB base is named $BASE_NAME"
  # NocoDB API tokens are bound to the base they are created in
  # (nc_api_tokens.base_id): a token can create another base but cannot work
  # inside it. So the base exists first, the tokens are created in it, and
  # this table is the first thing the installer's token makes.
  [ -n "$base_id" ] || die "no NocoDB base named $BASE_NAME: create it in the NocoDB UI, create the tokens inside it, and re-run"
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

# row_set APP KEY VALUE: changes an existing row's value (creates it if absent).
row_set() {
  local id; id=$(jq -r --arg a "$1" --arg k "$2" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].Id // ""' <<<"$ROWS_JSON")
  if [ -z "$id" ]; then row_ensure "$1" "$2" "$3" false ""; return; fi
  note "row $1/$2 updated: $3"
  (( DRY )) || nc "/api/v2/tables/$TABLE_ID/records" -X PATCH --data "$(jq -n --argjson id "$id" --arg v "$3" '[{Id:$id, settingValue:$v}]')" >/dev/null
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

# IPv4 CIDR arithmetic for merging trustedCIDR: an entry already inside an
# existing one is not added again (10.247.23.0/24 is inside 10.0.0.0/8).
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
cidr_contains() { # OUTER INNER
  local outer=$1 inner=$2 oplen iplen mask
  [[ $outer == */* ]] && oplen=${outer#*/} || oplen=32; outer=${outer%/*}
  [[ $inner == */* ]] && iplen=${inner#*/} || iplen=32; inner=${inner%/*}
  (( iplen >= oplen )) || return 1
  mask=$(( oplen == 0 ? 0 : (0xFFFFFFFF << (32 - oplen)) & 0xFFFFFFFF ))
  (( ($(ip2int "$outer") & mask) == ($(ip2int "$inner") & mask) ))
}
cidr_union() { # CURRENT-LIST ADD-LIST -> CURRENT plus the entries it does not already cover
  local out=$1 entry existing covered cur adds
  IFS=, read -ra adds <<<"$2"
  for entry in "${adds[@]}"; do
    entry=${entry// /}; [ -n "$entry" ] || continue; covered=0
    IFS=, read -ra cur <<<"$out"
    for existing in "${cur[@]}"; do
      existing=${existing// /}; [ -n "$existing" ] || continue
      if cidr_contains "$existing" "$entry"; then covered=1; break; fi
    done
    (( covered )) || out="${out:+$out,}$entry"
  done
  printf '%s' "$out"
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

# ── Application databases and accounts, created where root is ───────────────

# repo_script REPO LOCAL_DIR SCRIPT [docker -e ...]: runs an application's own
# scripts/<SCRIPT> (its checkout beside this one when present, otherwise a
# shallow clone at --branch) in a throwaway MySQL client on the platform network.
repo_script() {
  local repo=$1 local_dir=$2 script=$3; shift 3
  local src=$local_dir tmp="" branch
  if [ ! -f "$src/scripts/$script" ]; then
    branch=$(repo_branch "$repo")
    if (( DRY )); then note "would fetch $repo@$branch for scripts/$script"; src=/nonexistent; else
      tmp=$(mktemp -d); git clone -q --depth 1 -b "$branch" "$GIT_BASE/$repo.git" "$tmp/$repo"; src="$tmp/$repo"
      [ -f "$src/scripts/$script" ] || die "$repo@$branch has no scripts/$script: that branch predates the platform layout. Promote $repo's dev branch to $branch (merge it), or run with --branch dev."
    fi
  fi
  note "$repo/scripts/$script"
  run docker run --rm --network "$PLATFORM_NETWORK" -v "$src/scripts:/scripts:ro" "$@" mysql:8.4 bash "/scripts/$script"
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}

# Every application's database and account, created here with root, with the
# passwords in the rows the applications already read. The applications' host
# then needs no MySQL credential of its own: Echo's deploy-time jobs run as
# echo_admin, an account with all rights on echo_db and nothing else.
database_accounts() {
  local root; root=$(env_get "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD)
  [ -n "$root" ] || (( DRY )) || die "MYSQL_ROOT_PASSWORD is missing from $SELF_DIR/.env"
  local publish; publish=${MYSQL_PUBLISH:-$(env_get "$SELF_DIR/.env" MYSQL_PUBLISH)}
  # Published, the applications derive lsdb.<PARENT_DOMAIN> and need no row;
  # on loopback they share this host and use the container's name.
  local app_db_host="lsdb.$PARENT_DOMAIN"
  if [ -z "$publish" ]; then
    app_db_host=platform-mysql-local
    row_ensure identity DB_HOST "$app_db_host" false "MySQL host holding platform_db. Unset derives lsdb.<PARENT_DOMAIN>."
    row_ensure echo DB_HOST "$app_db_host" false "Echo application database host. Unset derives lsdb.<PARENT_DOMAIN>."
  fi
  local client=(docker run --rm --network "$PLATFORM_NETWORK" -e MYSQL_PWD="$root")

  log "Identity: platform_db and the identity account"
  row_ensure identity DB_USER identity false "MySQL user for platform_db; created by identity/scripts/db-users.sh."
  row_ensure identity DB_NAME platform_db false "Identity's database."
  row_default identity DB_PASSWORD "$(secret)" true "Password for DB_USER; the same value identity/scripts/db-users.sh sets."
  repo_script identity "$DIR/identity" db-users.sh -e DB_HOST=platform-mysql-local -e DB_PASSWORD="$ROW_VALUE" -e MYSQL_ADMIN_PASSWORD="$root"

  log "AidaAdmin: aida_admin_db and the aida_admin_app account"
  row_default aida-admin AIDA_ADMIN_DATABASE_URL "mysql://aida_admin_app:$(secret)@$app_db_host:3306/aida_admin_db" true "AidaAdmin's own store (OAuth state, receipts, audit); the account is created by AidaAdmin/scripts/db-users.sh from this URL."
  repo_script AidaAdmin "$DIR/aida/AidaAdmin" db-users.sh -e AIDA_ADMIN_DATABASE_URL="$ROW_VALUE" -e DB_HOST=platform-mysql-local -e MYSQL_ADMIN_PASSWORD="$root"

  log "Echo: echo_db schema, echo_web and echo_service, and echo_admin for its deploy-time jobs"
  row_ensure echo DB_NAME echo_db false "Echo application database; restart the pool after changes."
  row_ensure echo-web DB_USER echo_web false "EchoWeb's read-only account, created by AidaPlatformDB/echo's db-users job."
  row_ensure echo-service DB_USER echo_service false "EchoService's account, created by AidaPlatformDB/echo's db-users job."
  row_default echo-web DB_PASSWORD "$(secret)" true "Same value as ECHO_WEB_DB_PASSWORD in the Echo environment's .env."
  local web_pw=$ROW_VALUE
  row_default echo-service DB_PASSWORD "$(secret)" true "Same value as ECHO_SERVICE_DB_PASSWORD in the Echo environment's .env."
  local service_pw=$ROW_VALUE
  # Schema first: the read-only grants name the routines the migrations create.
  note "echo/scripts/migrate.sh"
  run "${client[@]}" -v "$SELF_DIR/echo/init:/init:ro" -v "$SELF_DIR/echo/scripts:/scripts:ro" \
    -e DB_HOST=platform-mysql-local -e DB_USER=root -e MYSQL_DATABASE=echo_db -e MIGRATIONS_DIR=/init mysql:8.4 bash /scripts/migrate.sh
  note "echo/scripts/db-users.sh"
  run "${client[@]}" -v "$SELF_DIR/echo/scripts:/scripts:ro" -e DB_HOST=platform-mysql-local -e MYSQL_ADMIN_PASSWORD="$root" \
    -e ECHO_WEB_DB_PASSWORD="$web_pw" -e ECHO_SERVICE_DB_PASSWORD="$service_pw" mysql:8.4 bash /scripts/db-users.sh
  row_ensure echo MYSQL_ADMIN_USER echo_admin false "Account the Echo environment's migration and account jobs run as: all rights on echo_db and CREATE USER, nothing else. Never the MySQL root."
  row_default echo MYSQL_ADMIN_PASSWORD "$(secret)" true "Password for MYSQL_ADMIN_USER; the Echo environment's .env carries the same value for its jobs."
  local admin_pw=$ROW_VALUE
  note "echo_admin"
  run "${client[@]}" mysql:8.4 mysql -h platform-mysql-local -uroot -e "CREATE USER IF NOT EXISTS 'echo_admin'@'%' IDENTIFIED BY '$admin_pw'; ALTER USER 'echo_admin'@'%' IDENTIFIED BY '$admin_pw'; GRANT ALL PRIVILEGES ON \`echo\\_db\`.* TO 'echo_admin'@'%' WITH GRANT OPTION; GRANT CREATE USER ON *.* TO 'echo_admin'@'%';"
}

# ── Phase a: the database host ───────────────────────────────────────────────

phase_database() {
  log "Database host: MySQL and NocoDB from $SELF_DIR"
  prereqs docker git jq openssl curl
  ask_parent_domain
  ask ENVIRONMENT_NAME --environment-name "Environment name (dev, staging, prod)" dev
  NOCODB_BASE_URL=${NOCODB_BASE_URL:-https://nocodb.$PARENT_DOMAIN}
  # Loopback serves applications on this host; other hosts need MySQL on an
  # address they can reach, and a name for it.
  if [ -z "$MYSQL_PUBLISH" ] && [ -z "$(env_get "$SELF_DIR/.env" MYSQL_PUBLISH)" ] && ! (( YES )) && { : < /dev/tty; } 2>/dev/null; then
    local answer
    read -r -p "Will the applications run on other hosts? MySQL then listens on 0.0.0.0:3306 as lsdb.$PARENT_DOMAIN [y/N] " answer < /dev/tty
    case ${answer,,} in y|yes) MYSQL_PUBLISH=0.0.0.0:3306 ;; esac
  fi

  log "External networks and the data directories"
  ensure_proxy_network
  ensure_network "$PLATFORM_NETWORK" "$PLATFORM_SUBNET"
  ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET" --internal
  local data_dir=${DATA_DIR:-/var/lib/aidaplatformdb}
  ensure_dir "$data_dir/mysql"
  ensure_dir "$data_dir/nocodb"

  log "$SELF_DIR/.env"
  env_set "$SELF_DIR/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_set "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD "$(secret)"
  env_set "$SELF_DIR/.env" NC_AUTH_JWT_SECRET "$(secret)"
  [ -n "$MYSQL_PUBLISH" ] && env_set "$SELF_DIR/.env" MYSQL_PUBLISH "$MYSQL_PUBLISH"
  [ -n "$DATA_DIR" ] && env_set "$SELF_DIR/.env" DATA_DIR "$DATA_DIR"

  local unmigrated; unmigrated=$(unmigrated_volumes "$data_dir")
  if [ -n "$unmigrated" ]; then
    die "the data is still in the Docker volume(s) $unmigrated while $data_dir is empty: starting now would bring up a fresh, empty instance beside it. Run './install.sh migrate-data' first, then re-run."
  fi
  log "Starting MySQL and NocoDB"
  run docker compose --project-directory "$SELF_DIR" up -d
  wait_for "MySQL" 180 sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" platform-mysql-local)" = healthy ]'
  wait_for "NocoDB" 180 curl -fsS -o /dev/null http://127.0.0.1:18087/
  NOCODB_API_URL=http://127.0.0.1:18087

  log "Claim NocoDB"
  note "Route $NOCODB_BASE_URL at the reverse proxy to platform-nocodb-local:8080 on $PROXY_NETWORK,"
  note "open it, and sign up: the first account becomes NocoDB's super admin. Then:"
  note "  1. create a base named $BASE_NAME (API tokens are bound to the base they are"
  note "     created in, so it has to exist before the tokens do),"
  note "  2. in that base, create one API token per application: installer, identity,"
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
    database_accounts
  fi

  local publish; publish=${MYSQL_PUBLISH:-$(env_get "$SELF_DIR/.env" MYSQL_PUBLISH)}
  log "Done. What only you can do:"
  note "1. NocoDB holds every secret the platform has. Block $NOCODB_BASE_URL from the public"
  note "   internet at the reverse proxy, or allow only trustedCIDR."
  note "2. The MySQL root password is: $( (( DRY )) && echo '<generated>' || env_get "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD )"
  note "   It lives in $SELF_DIR/.env (mode 600) and nowhere else — not in NocoDB, where every"
  note "   application's token could read it. Nothing else needs it: the applications' accounts were"
  note "   created here and their passwords are their own rows."
  note "   The data is under $data_dir (mysql/, nocodb/): back that path up."
  if [ -n "$publish" ]; then
    note "3. MySQL listens on $publish: firewall it to trustedCIDR, and point lsdb.$PARENT_DOMAIN"
    note "   (the name the applications derive) at this host's private address."
  else
    note "3. MySQL listens on 127.0.0.1 only: applications on other hosts cannot reach it. For that,"
    note "   set MYSQL_PUBLISH=0.0.0.0:3306 in $SELF_DIR/.env and run docker compose up -d here."
  fi
  return 0
}

# ── migrate-data: named volumes → DATA_DIR ───────────────────────────────────

# unmigrated_volumes DATA_DIR: the named volumes an older checkout used that
# still hold data while the host directory compose.yaml now mounts is empty.
# Starting on that empty directory would bring up a fresh, empty MySQL or
# NocoDB beside the real data — the one thing this installer must never do.
unmigrated_volumes() {
  local data_dir=$1 found=""
  local volumes=(platform-mysql-data platform-nocodb-data) dirs=("$data_dir/mysql" "$data_dir/nocodb") i
  for i in 0 1; do
    docker volume inspect "${volumes[$i]}" >/dev/null 2>&1 || continue
    [ -d "${dirs[$i]}" ] && [ -n "$(ls -A "${dirs[$i]}" 2>/dev/null)" ] && continue
    found+="${volumes[$i]} "
  done
  printf '%s' "$found"
}

# fresh_instance DIR KIND: true when DIR holds a MySQL/NocoDB instance that was
# initialised empty (no application database; no PlatformConfig base) — what a
# start on an empty directory leaves behind, and safe to set aside.
fresh_instance() {
  local dir=$1 kind=$2
  case $kind in
    mysql) [ -d "$dir/mysql" ] && [ ! -d "$dir/platform_db" ] && [ ! -d "$dir/echo_db" ] && [ ! -d "$dir/aida_admin_db" ] && [ ! -d "$dir/aidacalls_db" ] ;;
    nocodb) [ -f "$dir/noco.db" ] && have python3 && [ "$(python3 - "$dir/noco.db" <<'PY'
import sqlite3, sys
try:
    c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
    print(c.execute("select count(*) from nc_bases_v2 where deleted = 0 and title = 'PlatformConfig'").fetchone()[0])
except Exception:
    print("?")
PY
)" = 0 ] ;;
    *) return 1 ;;
  esac
}

# copy_volume_to_dir VOLUME DIR: everything in the volume, ownership and modes
# preserved, into a directory that must be empty.
copy_volume_to_dir() {
  local volume=$1 dir=$2
  ensure_dir "$dir"
  run docker run --rm -v "$volume:/src:ro" -v "$dir:/dst" alpine sh -c 'cp -a /src/. /dst/'
}

phase_migrate_data() {
  local data_dir=${DATA_DIR:-$(env_get "$SELF_DIR/.env" DATA_DIR)}
  data_dir=${data_dir:-/var/lib/aidaplatformdb}
  log "Move MySQL's and NocoDB's data from Docker volumes to $data_dir"
  prereqs docker
  [ -n "$DATA_DIR" ] && env_set "$SELF_DIR/.env" DATA_DIR "$DATA_DIR"

  local volumes=(platform-mysql-data platform-nocodb-data) dirs=("$data_dir/mysql" "$data_dir/nocodb") kinds=(mysql nocodb) todo=() aside=() i
  for i in 0 1; do
    if ! docker volume inspect "${volumes[$i]}" >/dev/null 2>&1; then
      note "no volume ${volumes[$i]}: ${dirs[$i]} is already the data"; continue
    fi
    if [ -d "${dirs[$i]}" ] && [ -n "$(ls -A "${dirs[$i]}" 2>/dev/null)" ]; then
      if fresh_instance "${dirs[$i]}" "${kinds[$i]}"; then
        note "${dirs[$i]} holds a fresh, empty ${kinds[$i]} (started on the empty directory); it will be set aside and the volume's data used"
        aside+=("$i")
      else
        die "${dirs[$i]} is not empty, holds real data, and volume ${volumes[$i]} still exists. Decide which one is current, remove the other, and re-run."
      fi
    fi
    todo+=("$i")
  done
  if [ "${#todo[@]}" -eq 0 ]; then log "Nothing to migrate"; return 0; fi

  log "Stopping MySQL and NocoDB while their data is copied"
  run docker compose --project-directory "$SELF_DIR" stop
  local stamp; stamp=$(date +%Y%m%d%H%M%S)
  for i in "${aside[@]}"; do
    note "${dirs[$i]} -> ${dirs[$i]}.empty-$stamp (delete it once satisfied)"
    run mv "${dirs[$i]}" "${dirs[$i]}.empty-$stamp"
  done
  for i in "${todo[@]}"; do
    note "${volumes[$i]} -> ${dirs[$i]}"
    copy_volume_to_dir "${volumes[$i]}" "${dirs[$i]}"
  done
  # MySQL's data directory must not be world-writable; the volume's root was.
  if [ -d "$data_dir/mysql" ] || (( DRY )); then run chmod 750 "$data_dir/mysql"; fi

  log "Starting on the host directories"
  run docker compose --project-directory "$SELF_DIR" up -d
  wait_for "MySQL" 180 sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" platform-mysql-local)" = healthy ]'
  wait_for "NocoDB" 180 curl -fsS -o /dev/null http://127.0.0.1:18087/
  if ! (( DRY )); then
    note "databases now served from $data_dir/mysql:"
    docker exec -e MYSQL_PWD="$(env_get "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD)" platform-mysql-local \
      mysql -uroot -N -e "SELECT CONCAT('  ', table_schema, ': ', COUNT(*), ' tables') FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema"
    note "NocoDB store: $(du -sh "$data_dir/nocodb/noco.db" 2>/dev/null | cut -f1) noco.db"
  fi

  log "The old volumes are now copies"
  local answer=y
  if ! (( YES )) && { : < /dev/tty; } 2>/dev/null; then
    read -r -p "Remove volumes ${volumes[*]}? [Y/n] " answer < /dev/tty
  fi
  case ${answer:-y} in n|N|no|NO) note "kept; remove them with docker volume rm when satisfied" ;;
    *) for i in "${todo[@]}"; do run docker volume rm "${volumes[$i]}"; done ;; esac
}

# ── Phase b: the application host ────────────────────────────────────────────

phase_apps() {
  log "Application host: Identity, AidaAdmin, AidaAgent and the Echo environment under $DIR"
  prereqs docker git jq openssl curl
  ask_parent_domain
  ask ENVIRONMENT_NAME --environment-name "Environment name (dev, staging, prod)" dev
  NOCODB_BASE_URL=${NOCODB_BASE_URL:-https://nocodb.$PARENT_DOMAIN}
  ask TOKEN_IDENTITY --token-identity "NocoDB API token for identity"
  ask TOKEN_AIDA_ADMIN --token-aida-admin "NocoDB API token for aida-admin"
  ask TOKEN_AIDA_AGENT --token-aida-agent "NocoDB API token for aida-agent"
  ask TOKEN_ECHO_WEB --token-echo-web "NocoDB API token for echo-web"
  ask TOKEN_ECHO_SERVICE --token-echo-service "NocoDB API token for echo-service"
  NOCODB_TOKEN=${NOCODB_TOKEN:-$TOKEN_IDENTITY}

  log "PlatformConfig"
  ensure_platformconfig
  row_ensure '*' PARENT_DOMAIN "$PARENT_DOMAIN" false "Apex domain (X.TLD) every application lives under; apps derive https://<app>.<PARENT_DOMAIN> from it."
  row_ensure '*' ENVIRONMENT_NAME "$ENVIRONMENT_NAME" false "dev, staging or prod; shown by the applications so nobody mistakes one environment for another."
  # trustedCIDR is platform-wide; the database host wrote its own networks, and
  # this host's (its Docker subnets and its address, as the other hosts see
  # its calls) must be in it too, or nothing here can call anything.
  local current_cidr proposed_cidr; current_cidr=$(row_get '*' trustedCIDR)
  proposed_cidr=$(cidr_union "$current_cidr" "$(default_trusted_cidr)")
  if [ -n "$current_cidr" ] && [ "$proposed_cidr" != "$current_cidr" ]; then
    note "trustedCIDR ($current_cidr) does not cover this host; proposing to add its networks"
  fi
  ask TRUSTED_CIDR --trusted-cidr "trustedCIDR: the networks the platform's servers sit on" "$proposed_cidr"
  if [ -z "$current_cidr" ]; then
    row_ensure '*' trustedCIDR "$TRUSTED_CIDR" false "IPv4 CIDRs (comma-separated) the platform's servers sit on. One value for the whole platform: every application admits server-to-server callers by it."
  elif [ "$TRUSTED_CIDR" != "$current_cidr" ]; then
    row_set '*' trustedCIDR "$TRUSTED_CIDR"
  else
    note "row */trustedCIDR kept"
  fi

  # MySQL: the container from `install.sh database` when it is on this host,
  # otherwise the name the rows (or the platform convention) give it.
  local db_local=0 db_default
  db_default=$(row_get echo DB_HOST); db_default=${db_default:-lsdb.$PARENT_DOMAIN}
  if docker container inspect platform-mysql-local >/dev/null 2>&1; then db_default=platform-mysql-local; fi
  ask DB_HOST --db-host "MySQL host as the applications reach it" "$db_default"
  [ "$DB_HOST" = platform-mysql-local ] && db_local=1
  if ! (( db_local )) && ! timeout 5 bash -c "exec 3<>/dev/tcp/$DB_HOST/3306" 2>/dev/null; then
    note "MySQL at $DB_HOST:3306 is not reachable from this host. On the database host, MySQL must"
    note "listen beyond loopback (MYSQL_PUBLISH=0.0.0.0:3306 in its AidaPlatformDB/.env, then"
    note "docker compose up -d; firewall it to trustedCIDR) and $DB_HOST must resolve to it."
    (( DRY )) || die "cannot reach $DB_HOST:3306"
  fi
  # The database host created every account and left the passwords in the rows,
  # so nothing is asked here. Without those rows (a database host set up before
  # that step existed) the accounts are created from here with root instead.
  local accounts_done=0 admin_user admin_pw
  admin_pw=$(row_get echo MYSQL_ADMIN_PASSWORD)
  if [ -n "$admin_pw" ]; then
    admin_user=$(row_get echo MYSQL_ADMIN_USER); admin_user=${admin_user:-echo_admin}; accounts_done=1
    note "MySQL accounts exist (created by 'install.sh database'); Echo's jobs run as $admin_user"
  else
    admin_user=root
    if (( db_local )); then MYSQL_ADMIN_PASSWORD=${MYSQL_ADMIN_PASSWORD:-$(env_get "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD)}; fi
    [ -n "$MYSQL_ADMIN_PASSWORD" ] || note "The database host has not created the applications' accounts (re-run 'install.sh database' there, or give its MYSQL_ROOT_PASSWORD from AidaPlatformDB/.env here, used once and kept only in echo/.env for Echo's jobs)."
    ask MYSQL_ADMIN_PASSWORD --mysql-admin-password "MySQL root password on $DB_HOST"
    admin_pw=$MYSQL_ADMIN_PASSWORD
  fi

  log "External networks and volumes"
  ensure_proxy_network
  ensure_network "$PLATFORM_NETWORK" "$PLATFORM_SUBNET"
  if (( db_local )); then ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET" --internal; else ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET"; fi
  ensure_volume aida-admin-assets
  ensure_volume echo-media-data
  ensure_volume echo-service-logs

  log "Checkouts ($BRANCH)"
  # The Echo environment includes ../AidaPlatformDB/echo/compose.yaml, so this
  # checkout has to sit beside it under that name.
  if [ "$(dirname "$SELF_DIR")" = "$DIR" ] && [ "$(basename "$SELF_DIR")" != AidaPlatformDB ]; then
    die "this checkout is $SELF_DIR; the Echo environment expects it at $DIR/AidaPlatformDB — rename it"
  fi
  [ "$SELF_DIR" = "$DIR/AidaPlatformDB" ] || clone_or_update AidaPlatformDB "$DIR/AidaPlatformDB"
  clone_or_update identity "$DIR/identity"
  # identity's platform layout (compose.yaml, scripts/db-users.sh) exists only
  # from a certain point; an older branch would bring up its bundled MySQL.
  for f in compose.yaml scripts/db-users.sh; do
    [ -f "$DIR/identity/$f" ] || (( DRY )) || die "identity@$(git -C "$DIR/identity" branch --show-current) has no $f: that branch predates the platform layout. Promote identity's dev branch (merge it into the default branch), or run with --branch dev."
  done
  clone_or_update AidaAdmin "$DIR/aida/AidaAdmin"
  clone_or_update AidaAgent "$DIR/aida/AidaAgent"
  clone_or_update EchoWeb "$DIR/echo/EchoWeb"
  clone_or_update EchoService "$DIR/echo/EchoService"
  clone_or_update EchoMedia "$DIR/echo/EchoMedia"
  local f
  [ -f "$DIR/echo/EchoWeb/deploy/environment/compose.yaml" ] || (( DRY )) || die "EchoWeb@$(git -C "$DIR/echo/EchoWeb" branch --show-current) has no deploy/environment (the Echo environment template): that branch predates it; use one that has it"
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
  env_set "$echo_env" MYSQL_ADMIN_USER "$admin_user"
  env_set "$echo_env" MYSQL_ADMIN_PASSWORD "$admin_pw"
  local web_pw service_pw
  web_pw=$(row_get echo-web DB_PASSWORD); service_pw=$(row_get echo-service DB_PASSWORD)
  env_set "$echo_env" ECHO_WEB_DB_PASSWORD "${web_pw:-$(secret)}"
  env_set "$echo_env" ECHO_SERVICE_DB_PASSWORD "${service_pw:-$(secret)}"
  # Image tags: <environment>-<commit>. The environment name is written
  # literally — Compose resolves a .env reference only to variables defined
  # above it in the file, and the applications read ENVIRONMENT_NAME from
  # PlatformConfig, not from here. The *_SHORT stamps come from deploy.sh.
  env_set "$echo_env" ECHO_WEB_TAG "$ENVIRONMENT_NAME"'-${ECHO_WEB_SHORT:-${BUILD_REVISION_SHORT-local}}'
  env_set "$echo_env" ECHO_SERVICE_TAG "$ENVIRONMENT_NAME"'-${ECHO_SERVICE_SHORT:-${BUILD_REVISION_SHORT-local}}'
  env_set "$echo_env" ECHO_MEDIA_TAG "$ENVIRONMENT_NAME"'-${ECHO_MEDIA_SHORT:-${BUILD_REVISION_SHORT-local}}'
  # An earlier installer wrote the tags as ${ENVIRONMENT_NAME}-... with the
  # variable defined below them, which Compose resolved to "-<commit>".
  if [ -f "$echo_env" ] && grep -q '^ECHO_[A-Z]*_TAG=\${ENVIRONMENT_NAME}-' "$echo_env"; then
    note "$echo_env: rewriting the image tags to $ENVIRONMENT_NAME-<commit> (Compose could not resolve \${ENVIRONMENT_NAME} there)"
    run sed -i "s/^\(ECHO_[A-Z]*_TAG=\)\${ENVIRONMENT_NAME}-/\1$ENVIRONMENT_NAME-/; /^ENVIRONMENT_NAME=/d" "$echo_env"
  fi

  log "PlatformConfig rows"
  # One shared secret for redeeming Identity handoff codes; Identity mints it if absent.
  local client_secret identity_db_password aida_admin_password aida_admin_url
  row_default identity IDENTITY_CLIENT_SECRET "$(secret)" true "Shared secret applications present at POST /api/token while IDENTITY_APP_AUTH_MODE is secret or dual."
  client_secret=$ROW_VALUE
  row_ensure echo-web IDENTITY_CLIENT_SECRET "$client_secret" true "Shared secret EchoWeb presents to Identity /api/token; same value as identity/IDENTITY_CLIENT_SECRET."
  row_ensure aida-admin ID_CLIENT_SECRET "$client_secret" true "Shared secret AidaAdmin presents to Identity /api/token; same value as identity/IDENTITY_CLIENT_SECRET."

  # Database coordinates and accounts: normally rows the database host wrote.
  # The fallback (no such rows) creates them from here with root.
  if ! (( accounts_done )); then
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
  fi

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

  if ! (( accounts_done )); then
    log "MySQL accounts on $DB_HOST (fallback: created from here with root)"
    repo_script identity "$DIR/identity" db-users.sh \
      -e DB_HOST="$DB_HOST" -e DB_PASSWORD="$identity_db_password" -e MYSQL_ADMIN_PASSWORD="$MYSQL_ADMIN_PASSWORD"
    repo_script AidaAdmin "$DIR/aida/AidaAdmin" db-users.sh \
      -e AIDA_ADMIN_DATABASE_URL="$aida_admin_url" -e DB_HOST="$DB_HOST" -e MYSQL_ADMIN_PASSWORD="$MYSQL_ADMIN_PASSWORD"
    note "echo_web and echo_service are created by the Echo environment's own jobs at deploy"
  fi

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
  ask_parent_domain
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

ARGS=("$@")
PHASE=""
while [ $# -gt 0 ]; do
  case $1 in
    database|apps|officepulse|all|migrate-data) PHASE=$1 ;;
    --branch) BRANCH=$2; shift ;;
    --dir) DIR=$(readlink -f "$2"); DIR_GIVEN=1; shift ;;
    --parent-domain) PARENT_DOMAIN=$2; shift ;;
    --environment-name) ENVIRONMENT_NAME=$2; shift ;;
    --nocodb-base-url) NOCODB_BASE_URL=${2%/}; shift ;;
    --nocodb-token) NOCODB_TOKEN=$2; shift ;;
    --trusted-cidr) TRUSTED_CIDR=$2; shift ;;
    --db-host) DB_HOST=$2; shift ;;
    --mysql-admin-password) MYSQL_ADMIN_PASSWORD=$2; shift ;;
    --mysql-publish) MYSQL_PUBLISH=$2; shift ;;
    --data-dir) DATA_DIR=$(readlink -f "$2"); shift ;;
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

# Run from a checkout, the install root is wherever that checkout was cloned
# (the applications go beside it: /opt/AidaPlatformDB -> /opt/identity, ...)
# and the branch is the checkout's own, so a dev checkout installs dev apps.
if [ -f "$SELF_DIR/compose.yaml" ] && [ -d "$SELF_DIR/echo" ]; then
  (( DIR_GIVEN )) || DIR=$(dirname "$SELF_DIR")
  g=(git -c safe.directory='*' -C "$SELF_DIR")
  current=$("${g[@]}" branch --show-current 2>/dev/null || true)
  # Always the current installer: a checkout behind its branch is brought up
  # to date and re-run, so an old install.sh cannot install the wrong thing;
  # one whose branch no longer exists at origin (promoted and deleted) moves
  # to origin's default branch first.
  if [ "${INSTALL_UPDATED:-}" != 1 ] && [ -n "$current" ] && "${g[@]}" fetch -q --prune origin 2>/dev/null; then
    if ! "${g[@]}" show-ref -q --verify "refs/remotes/origin/$current"; then
      default=$("${g[@]}" ls-remote --symref origin HEAD 2>/dev/null | awk '$1=="ref:" && $3=="HEAD" {sub("refs/heads/", "", $2); print $2; exit}')
      [ -n "$default" ] || die "branch $current no longer exists at origin and its default branch could not be read; check out the right branch in $SELF_DIR and re-run"
      log "Branch $current no longer exists at origin: switching this checkout to $default and starting over"
      "${g[@]}" checkout -q "$default" 2>/dev/null || "${g[@]}" checkout -q -b "$default" "origin/$default"
      "${g[@]}" pull -q --ff-only || die "git pull --ff-only failed in $SELF_DIR: update it by hand and re-run"
      INSTALL_UPDATED=1 exec "$SELF_DIR/install.sh" "${ARGS[@]}"
    fi
    behind=$("${g[@]}" rev-list --count "HEAD..origin/$current" 2>/dev/null || echo 0)
    if [ "${behind:-0}" -gt 0 ]; then
      log "This checkout is $behind commit(s) behind origin/$current: updating it and starting over"
      "${g[@]}" pull -q --ff-only || die "git pull --ff-only failed in $SELF_DIR: update it by hand and re-run"
      INSTALL_UPDATED=1 exec "$SELF_DIR/install.sh" "${ARGS[@]}"
    fi
  fi
  [ -n "$BRANCH" ] || BRANCH=$current
fi
BRANCH=${BRANCH:-main}

# Piped from GitHub rather than run from a checkout: get the checkout this
# script is the front of (compose.yaml, echo/, and itself) and carry on there.
if [ ! -f "$SELF_DIR/compose.yaml" ] || [ ! -d "$SELF_DIR/echo" ]; then
  log "Not running from an AidaPlatformDB checkout: cloning $BRANCH into $DIR/AidaPlatformDB"
  prereqs git
  DRY=0 clone_or_update AidaPlatformDB "$DIR/AidaPlatformDB"
  [ -x "$DIR/AidaPlatformDB/install.sh" ] || die "branch $BRANCH of AidaPlatformDB has no install.sh yet; use --branch dev (and the dev URL) until it is promoted"
  exec "$DIR/AidaPlatformDB/install.sh" "${ARGS[@]}"
fi
(( DRY )) && log "Dry run: nothing below is applied"

case $PHASE in
  database) phase_database ;;
  apps) phase_apps ;;
  officepulse) phase_officepulse ;;
  all) phase_database; phase_apps ;;
  migrate-data) phase_migrate_data ;;
esac
