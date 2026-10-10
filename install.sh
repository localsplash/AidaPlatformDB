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
# domain. Re-running detects saved values: Enter keeps them, and secrets
# stay hidden. Existing database accounts are kept. README.md describes each phase.
set +x # Passwords/tokens must not appear even when invoked with bash -x.
set -euo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}")
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

# Persisted values are defaults, not explicit overrides. Never source an .env.
declare -A SAVED_VALUES=() GIVEN_INPUTS=()
OFFICEPULSE_ENV_FILE=/etc/aida-integration/env
SAVE_INSTALLER_TOKEN=0

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
  --yes                    never prompt; use saved values/defaults unless explicitly overridden
  --no-deploy              clone, write .env files, create accounts and rows, but do not build or start
  --dry-run                preview changes with secrets hidden; skip checkout auto-update
  -h, --help
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { echo "install: $*" >&2; exit 2; }
# Dry runs print the command with secret-looking values masked.
run() {
  if ! (( DRY )); then "$@"; return; fi
  local arg hide_next=0
  printf '    +'
  for arg in "$@"; do
    if (( hide_next )); then arg='<hidden>'; hide_next=0
    elif [[ $arg == *=* ]] && is_secret_key "${arg%%=*}"; then arg="${arg%%=*}=<hidden>"
    elif [[ ${arg^^} == *'IDENTIFIED BY'* || $arg == *://*:*@* ]]; then arg='<credentials hidden>'
    elif [[ $arg == --* ]] && is_secret_key "$arg"; then hide_next=1
    fi
    printf ' %q' "$arg"
  done
  printf '\n'
}
have() { command -v "$1" >/dev/null 2>&1; }
secret() { openssl rand -hex 32; }

# A value explicitly supplied by flag/environment wins. Otherwise show the
# saved value (or fresh default) and let Enter keep it. /dev/tty also supports
# curl | bash. EOF is an abort, not permission to replace a saved secret.
is_secret_key() {
  local key=${1^^}; key=${key//-/_}
  [[ $key =~ (PASSWORD|PASS|SECRET|TOKEN|API_KEY|PRIVATE_KEY|PWD|DATABASE_URL) ]]
}
shown_value() {
  if [[ ${3:-false} = true || ${3:-false} = 1 ]] || is_secret_key "$1" || [[ $2 == *://*:*@* ]]; then
    printf '<configured; hidden>'
  else
    printf '%s' "$2"
  fi
}
validate_input() {
  case $1 in
    ENVIRONMENT_NAME) case $2 in dev|staging|prod) ;; *) die 'Environment name must be dev, staging or prod' ;; esac ;;
    DATA_DIR) [[ $2 == /* ]] || die 'DATA_DIR must be an absolute path' ;;
  esac
}
ask() {
  local var=$1 flag=$2 prompt=$3 default=${SAVED_VALUES[$1]:-${4:-}} value
  if [ -n "${!var}" ]; then
    validate_input "$var" "${!var}"
    note "$prompt: $(shown_value "$var" "${!var}") (selected)"
    return 0
  fi
  if (( YES )) || ! { : < /dev/tty; } 2>/dev/null; then
    [ -n "$default" ] || die "$prompt: give it with $flag"
    validate_input "$var" "$default"
    printf -v "$var" '%s' "$default"
    note "$prompt: $(shown_value "$var" "$default") (kept)"
    return 0
  fi
  if is_secret_key "$var"; then
    local hint='not echoed'
    [ -z "$default" ] || hint='configured; Enter to keep, or type a replacement; not echoed'
    IFS= read -rs -p "$prompt [$hint]: " value < /dev/tty || die "Input cancelled for $var"
    echo > /dev/tty
  else
    IFS= read -r -p "$prompt${default:+ [$default]}: " value < /dev/tty || die "Input cancelled for $var"
  fi
  printf -v "$var" '%s' "${value:-$default}"
  [ -n "${!var}" ] || die "$prompt is required"
  validate_input "$var" "${!var}"
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
      PARENT_DOMAIN=""; unset 'SAVED_VALUES[PARENT_DOMAIN]'; continue
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
    PARENT_DOMAIN=""; unset 'SAVED_VALUES[PARENT_DOMAIN]'
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
  local current; current=$(env_get "$file" "$key")
  if [ -n "$current" ]; then note "$file: $key=$(shown_value "$key" "$current") (kept)"; return; fi
  if (( DRY )); then note "$file: $key=$(shown_value "$key" "$value") (would set)"; return; fi
  [ -f "$file" ] || { : > "$file"; chmod 600 "$file"; }
  if grep -qE "^${key}=.+" "$file"; then return; fi
  sed -i "/^${key}=\s*$/d" "$file"
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

env_get() { # FILE KEY -> literal value; no eval or shell execution
  [ -f "$1" ] || return 0
  local line value='' decoded next i
  local pattern="^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*="
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $pattern ]] || continue
    value=${line#*=}; value=${value%$'\r'}
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ $value == \'* ]]; then
      value=${value#\'}; value=${value%\'*}
      value=${value//\\\'/\'}
    elif [[ $value == \"* ]]; then
      value=${value#\"}; value=${value%\"*}
      # Decode only the escapes emitted by env_write, without evaluating variables.
      decoded=''
      for ((i=0; i<${#value}; i++)); do
        next=${value:i:1}
        if [[ $next == \\ && $((i+1)) -lt ${#value} ]]; then
          case ${value:i+1:1} in
            '\'|'"'|'$'|'`') ((i+=1)); next=${value:i:1} ;;
          esac
        fi
        decoded+=$next
      done
      value=$decoded
    else
      value=${value%%[[:space:]]#*}
      value="${value%"${value##*[![:space:]]}"}"
    fi
  done < "$1"
  printf '%s' "$value"
}

# Only reviewed bootstrap inputs use replacement semantics. Generated database
# credentials still use env_set/row_default and are never rotated by a rerun.
env_write() { # FILE KEY VALUE
  local file=$1 key=$2 value=$3 current temp line quoted
  current=$(env_get "$file" "$key")
  if [ -n "$current" ] && [ "$current" = "$value" ]; then
    note "$file: $key=$(shown_value "$key" "$current") (kept)"
    return 0
  fi
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "$key must be a single-line bootstrap value"
  note "$file: $key=$(shown_value "$key" "$value") (saved)"
  (( DRY )) && return 0
  # Double-quote complex values and escape exactly the characters Compose and
  # systemd treat specially. In particular a trailing backslash must not swallow
  # the closing quote, and a literal dollar must not become interpolation.
  if [[ $value =~ ^[a-zA-Z0-9_./:@%+,=-]+$ ]]; then quoted=$value
  else
    quoted=${value//\\/\\\\}
    quoted=${quoted//\"/\\\"}
    quoted=${quoted//\$/\\\$}
    quoted="\"$quoted\""
  fi
  temp=$(mktemp "${file}.tmp.XXXXXX") || die "Cannot create temporary file beside $file"
  chmod 600 "$temp"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]] || printf '%s\n' "$line" >> "$temp"
    done < "$file"
    chown --reference="$file" "$temp" 2>/dev/null || { rm -f "$temp"; die "Cannot preserve ownership of $file"; }
  fi
  printf '%s=%s\n' "$key" "$quoted" >> "$temp"
  mv -f -- "$temp" "$file"
}

env_apply() { # Keep a per-app URL override on Enter; replace on an explicit change.
  if [ "$2" = NOCODB_BASE_URL ] && [ -z "${GIVEN_INPUTS[NOCODB_BASE_URL]:-}" ] &&
     [ "$3" = "${SAVED_VALUES[NOCODB_BASE_URL]:-}" ]; then
    env_set "$@"
  else
    env_write "$@"
  fi
}

ask_installer_token() { # Optional dedicated installer token; otherwise use the app token.
  if [ -n "${NOCODB_TOKEN:-${SAVED_VALUES[NOCODB_TOKEN]:-}}" ]; then
    ask NOCODB_TOKEN --nocodb-token "NocoDB installer API token"
    SAVE_INSTALLER_TOKEN=1
  else
    NOCODB_TOKEN=$1
  fi
}

saved_env() { # VAR FILE KEY; first nonblank source wins
  [ -z "${SAVED_VALUES[$1]:-}" ] || return 0
  local value; value=$(env_get "$2" "$3")
  [ -z "$value" ] || SAVED_VALUES[$1]=$value
  return 0
}

load_saved_inputs() {
  local var file
  for var in PARENT_DOMAIN ENVIRONMENT_NAME NOCODB_BASE_URL NOCODB_TOKEN TRUSTED_CIDR DB_HOST MYSQL_PUBLISH DATA_DIR MYSQL_ADMIN_PASSWORD TOKEN_IDENTITY TOKEN_AIDA_ADMIN TOKEN_AIDA_AGENT TOKEN_ECHO_WEB TOKEN_ECHO_SERVICE TOKEN_OFFICEPULSE; do
    [ -z "${!var}" ] || GIVEN_INPUTS[$var]=1
  done
  saved_env PARENT_DOMAIN "$SELF_DIR/.env" INSTALL_PARENT_DOMAIN
  saved_env ENVIRONMENT_NAME "$SELF_DIR/.env" INSTALL_ENVIRONMENT_NAME
  saved_env NOCODB_TOKEN "$SELF_DIR/.env" NOCODB_INSTALLER_TOKEN
  saved_env MYSQL_ADMIN_PASSWORD "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD
  saved_env MYSQL_PUBLISH "$SELF_DIR/.env" MYSQL_PUBLISH
  saved_env DATA_DIR "$SELF_DIR/.env" DATA_DIR
  saved_env TOKEN_IDENTITY "$DIR/identity/.env" NOCODB_API_TOKEN
  saved_env TOKEN_AIDA_ADMIN "$DIR/aida/AidaAdmin/.env" NOCODB_API_TOKEN
  saved_env TOKEN_AIDA_AGENT "$DIR/aida/AidaAgent/.env" NOCODB_API_TOKEN
  saved_env TOKEN_ECHO_WEB "$DIR/echo/.env" ECHO_WEB_NOCODB_API_TOKEN
  saved_env TOKEN_ECHO_SERVICE "$DIR/echo/.env" ECHO_SERVICE_NOCODB_API_TOKEN
  saved_env TOKEN_OFFICEPULSE "$OFFICEPULSE_ENV_FILE" NOCODB_API_TOKEN
  saved_env DB_HOST "$DIR/echo/.env" ECHO_DB_HOST
  local files=("$SELF_DIR/.env" "$DIR/identity/.env" "$DIR/aida/AidaAdmin/.env" "$DIR/aida/AidaAgent/.env" "$DIR/echo/.env")
  [ "$PHASE" != officepulse ] || files=("$OFFICEPULSE_ENV_FILE" "${files[@]}")
  for file in "${files[@]}"; do saved_env NOCODB_BASE_URL "$file" NOCODB_BASE_URL; done
  # Upgrade path for old installs without installer hints.
  local url=${NOCODB_BASE_URL:-${SAVED_VALUES[NOCODB_BASE_URL]:-}}
  if [[ $url =~ ^https?://nocodb\.([^/:]+)(:[0-9]+)?/?$ ]] && [ -z "${SAVED_VALUES[PARENT_DOMAIN]:-}" ]; then
    SAVED_VALUES[PARENT_DOMAIN]=${BASH_REMATCH[1]}
  fi
}

# Resolve authoritative shared settings before prompting when the saved endpoint
# is already up. This probe is GET-only; the normal phase still validates access.
load_saved_platform_inputs() {
  local url=${NOCODB_BASE_URL:-${SAVED_VALUES[NOCODB_BASE_URL]:-}} token=${NOCODB_TOKEN:-${SAVED_VALUES[NOCODB_TOKEN]:-}}
  if [ -z "$token" ]; then
    if [ "$PHASE" = officepulse ]; then token=${TOKEN_OFFICEPULSE:-${SAVED_VALUES[TOKEN_OFFICEPULSE]:-}}
    else token=${TOKEN_IDENTITY:-${SAVED_VALUES[TOKEN_IDENTITY]:-}}; fi
  fi
  [ -n "$url" ] && [ -n "$token" ] || return 0
  local bases tables base table rows page count offset=0 key value
  local client=(curl --connect-timeout 5 --max-time 15 -fsS -H "xc-token: $token")
  bases=$("${client[@]}" "$url/api/v2/meta/bases" 2>/dev/null) || return 0
  base=$(jq -er --arg t "$BASE_NAME" '[.list[] | select(.title==$t)] | select(length==1) | .[0].id' <<<"$bases") || return 0
  tables=$("${client[@]}" "$url/api/v2/meta/bases/$base/tables" 2>/dev/null) || return 0
  table=$(jq -er --arg t "$TABLE_NAME" '[.list[] | select(.title==$t)] | select(length==1) | .[0].id' <<<"$tables") || return 0
  rows='[]'
  while :; do
    page=$("${client[@]}" "$url/api/v2/tables/$table/records?limit=200&offset=$offset" 2>/dev/null) || return 0
    count=$(jq -er '.list | length' <<<"$page") || return 0
    rows=$(jq -s '.[0] + .[1].list' <(printf '%s' "$rows") <(printf '%s' "$page")) || return 0
    [ "$count" -ge 200 ] || break
    offset=$((offset + 200))
  done
  for key in PARENT_DOMAIN ENVIRONMENT_NAME; do
    value=$(jq -r --arg k "$key" '[.[] | select(.app=="*" and .settingKey==$k)] | if length==1 then .[0].settingValue // "" else "" end' <<<"$rows")
    [ -z "$value" ] || SAVED_VALUES[$key]=$value
  done
}

# After NocoDB starts, reconcile any offline hints with the actual rows. Explicit
# flag/env choices win; otherwise display the real current value before changes.
sync_platform_identity() {
  local var current
  for var in PARENT_DOMAIN ENVIRONMENT_NAME; do
    current=$(row_get '*' "$var")
    if [ -n "$current" ] && [ "$current" != "${!var}" ] && [ -z "${GIVEN_INPUTS[$var]:-}" ] &&
       [ "${!var}" = "${SAVED_VALUES[$var]:-${!var}}" ]; then
      SAVED_VALUES[$var]=$current
      printf -v "$var" '%s' ''
      if [ "$var" = PARENT_DOMAIN ]; then ask_parent_domain
      else ask ENVIRONMENT_NAME --environment-name "Environment name (dev, staging, prod)" dev; fi
    fi
    case $var in ENVIRONMENT_NAME) case $ENVIRONMENT_NAME in dev|staging|prod) ;; *) die 'Environment name must be dev, staging or prod' ;; esac ;; esac
    if [ -n "$current" ] && [ "$current" != "${!var}" ]; then row_set '*' "$var" "${!var}"
    else row_ensure '*' "$var" "${!var}" false 'Platform installation identity.'; fi
  done
  env_write "$SELF_DIR/.env" INSTALL_PARENT_DOMAIN "$PARENT_DOMAIN"
  env_write "$SELF_DIR/.env" INSTALL_ENVIRONMENT_NAME "$ENVIRONMENT_NAME"
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
    rows_load; note "base $BASE_NAME and table $TABLE_NAME found ($(jq length <<<"$ROWS_JSON") rows)"; TABLE_ID=dry; rename_settings_scopes; return
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
  rename_settings_scopes
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

# Scopes renamed in place, so every application reads its rows under the new
# name without re-entering a value. The bridge between OfficePulse's Asterisk
# and Aida's LiveKit agent is aida-pbx; AidaAdmin's read-only view of its
# database is aida-pbx-reader.
RENAMED_SCOPES=("officepulse aida-pbx" "aida-admin-runtime aida-pbx-reader")

rename_settings_scopes() {
  local pair old new ids key
  for pair in "${RENAMED_SCOPES[@]}"; do
    read -r old new <<<"$pair"
    ids=$(jq -r --arg o "$old" '[.[] | select(.app==$o) | .Id] | join(" ")' <<<"$ROWS_JSON")
    [ -n "$ids" ] || continue
    # A key present under both names is a person's call, not the installer's.
    key=$(jq -r --arg o "$old" --arg n "$new" '
      [.[] | select(.app==$n) | .settingKey] as $kept
      | [.[] | select(.app==$o and (.settingKey as $k | $kept | index($k))) | .settingKey] | .[0] // ""' <<<"$ROWS_JSON")
    [ -z "$key" ] || die "PlatformConfig has both $old/$key and $new/$key: $old was renamed $new, so delete the row you do not want and re-run"
    note "PlatformConfig scope $old renamed $new ($(wc -w <<<"$ids") rows)"
    if (( DRY )) || [ "$TABLE_ID" = dry ]; then continue; fi
    nc "/api/v2/tables/$TABLE_ID/records" -X PATCH \
      --data "$(jq -n --arg n "$new" --arg ids "$ids" '$ids | split(" ") | map({Id: tonumber, app: $n})')" >/dev/null ||
      die "could not rename PlatformConfig scope $old to $new"
  done
  if ! (( DRY )) && [ "$TABLE_ID" != dry ]; then rows_load; fi
}

row_get() { # APP KEY -> value ('' when absent or blank)
  jq -r --arg a "$1" --arg k "$2" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].settingValue // "" | tostring' <<<"$ROWS_JSON" | sed 's/^null$//'
}

# row_ensure APP KEY VALUE SECRET(true|false) DESCRIPTION: creates the row, or
# fills a blank one; a row that already has a value is left alone.
row_ensure() {
  local app=$1 key=$2 value=$3 secret=$4 desc=$5 id shown stored_secret
  stored_secret=$(jq -r --arg a "$app" --arg k "$key" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].bSecret // false' <<<"$ROWS_JSON")
  [[ $stored_secret != true && $stored_secret != 1 ]] || secret=true
  shown=$(shown_value "$key" "$value" "$secret")
  id=$(jq -r --arg a "$app" --arg k "$key" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].Id // ""' <<<"$ROWS_JSON")
  if [ -n "$id" ] && [ -n "$(row_get "$app" "$key")" ]; then note "row $app/$key=$(shown_value "$key" "$(row_get "$app" "$key")" "$secret") (kept)"; return; fi
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
  if [ -z "$id" ]; then row_ensure "$1" "$2" "$3" "$(is_secret_key "$2" && echo true || echo false)" ""; return; fi
  local hidden; hidden=$(jq -r --arg a "$1" --arg k "$2" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].bSecret // false' <<<"$ROWS_JSON")
  note "row $1/$2 updated: $(shown_value "$2" "$3" "$hidden")"
  (( DRY )) || nc "/api/v2/tables/$TABLE_ID/records" -X PATCH --data "$(jq -n --argjson id "$id" --arg v "$3" '[{Id:$id, settingValue:$v}]')" >/dev/null
  (( DRY )) || rows_load
}

# row_default APP KEY DEFAULT SECRET DESCRIPTION: the effective value ends up
# in ROW_VALUE (not echoed: a command substitution would run this in a subshell
# and the parent would never see the row it created).
ROW_VALUE=""
row_default() {
  # Retain trailing newlines in literal passwords; command substitution alone loses them.
  ROW_VALUE=$(row_get "$1" "$2"; printf '\001')
  ROW_VALUE=${ROW_VALUE%$'\001'}
  ROW_VALUE=${ROW_VALUE%$'\n'}
  if [ -n "$ROW_VALUE" ]; then
    local hidden=$4 stored_secret
    stored_secret=$(jq -r --arg a "$1" --arg k "$2" '[.[] | select(.app==$a and .settingKey==$k)] | .[0].bSecret // false' <<<"$ROWS_JSON")
    [[ $stored_secret != true && $stored_secret != 1 ]] || hidden=true
    note "row $1/$2=$(shown_value "$2" "$ROW_VALUE" "$hidden") (kept)"
    return
  fi
  row_ensure "$@"
  ROW_VALUE=$3
}


# ── Canonical application database settings ─────────────────────────────────

# Only the installer reads retired settings, to migrate existing credentials.
# Applications never fall back to these names. Values in canonical rows win.
db_decode() { # ENCODED OUTPUT_VAR; preserve literal %, quotes and trailing newlines
  local encoded=$1 decoded='' prefix rest byte character
  while [[ $encoded == *%* ]]; do
    prefix=${encoded%%\%*}; rest=${encoded#*%}
    [[ $rest =~ ^[0-9A-Fa-f]{2} ]] || die 'Legacy database setting has invalid percent encoding'
    byte=${rest:0:2}; [[ $byte != 00 ]] || die 'Legacy database setting cannot contain NUL bytes'
    printf -v character '%b' "\\x$byte"
    decoded+="$prefix$character"; encoded=${rest:2}
  done
  printf -v "$2" '%s' "$decoded$encoded"
}

# Returns ROW_VALUE without dropping trailing newlines from a stored password.
db_row_read() {
  ROW_VALUE=$(row_get "$1" "$2"; printf '\001')
  ROW_VALUE=${ROW_VALUE%$'\001'}; ROW_VALUE=${ROW_VALUE%$'\n'}
}

legacy_runtime_value() { # KEY -> ROW_VALUE, matching the former runtime scope order
  local scope
  for scope in aida-pbx aida '*'; do
    db_row_read "$scope" "$1"
    [ -z "$ROW_VALUE" ] || return 0
  done
}

has_database_password() {
  db_row_read "$1" DB_PASSWORD
  [ -z "$ROW_VALUE" ] || return 0
  case $1 in
    aida-admin) db_row_read aida-admin AIDA_ADMIN_DATABASE_URL ;;
    aida-pbx-reader) db_row_read aida-admin OFFICEPULSE_RUNTIME_DATABASE_URL ;;
    aida-pbx) legacy_runtime_value RUNTIME_MYSQL_PASSWORD ;;
  esac
  [ -n "$ROW_VALUE" ]
}

aida_database_accounts_ready() {
  has_database_password aida-admin && has_database_password aida-pbx && has_database_password aida-pbx-reader
}

# database_rows APP HOST NAME USER [LEGACY_APP LEGACY_URL_KEY]
# DB_ROW_* and DB_ROW_ARGS carry the exact values used for both rows and grants.
database_rows() {
  local app=$1 host=$2 database=$3 user=$4 password='' db_port=3306 legacy='' key complete=1
  for key in DB_HOST DB_NAME DB_USER DB_PASSWORD; do
    db_row_read "$app" "$key"; [ -n "$ROW_VALUE" ] || complete=0
  done
  if ! (( complete )); then
    if [ -n "${6:-}" ]; then db_row_read "$5" "$6"; legacy=$ROW_VALUE; fi
    if [ -n "$legacy" ]; then
      local re='^mysql://([^:@/?#]+):([^@/?#]*)@(\[[0-9A-Fa-f:.]+\]|[^:/?#]+)(:([0-9]+))?/([^/?#]+)$'
      [[ $legacy =~ $re ]] || die "Legacy $5/$6 is invalid; set $app DB_* rows explicitly"
      local parts=("${BASH_REMATCH[@]}")
      db_decode "${parts[1]}" user; db_decode "${parts[2]}" password
      [ -n "$password" ] || die "Legacy $5/$6 has no password; set $app/DB_PASSWORD explicitly"
      host=${parts[3]}; host=${host#[}; host=${host%]}
      db_port=${parts[5]:-3306}; database=${parts[6]}
      note "Migrating $5/$6 into $app DB_* rows (existing canonical values are kept)"
    elif [ "$app" = aida-pbx ]; then
      legacy_runtime_value RUNTIME_MYSQL_HOST; host=${ROW_VALUE:-$host}
      legacy_runtime_value RUNTIME_MYSQL_PORT; db_port=${ROW_VALUE:-$db_port}
      legacy_runtime_value RUNTIME_MYSQL_DATABASE; database=${ROW_VALUE:-$database}
      legacy_runtime_value RUNTIME_MYSQL_USER; user=${ROW_VALUE:-$user}
      legacy_runtime_value RUNTIME_MYSQL_PASSWORD; password=$ROW_VALUE
    fi
  fi
  row_default "$app" DB_HOST "$host" false 'MySQL hostname as this application reaches it; no connection URL is needed.'
  DB_ROW_HOST=$ROW_VALUE
  row_default "$app" DB_PORT "$db_port" false 'MySQL port (defaults to 3306).'
  DB_ROW_PORT=$ROW_VALUE
  row_default "$app" DB_NAME "$database" false 'Application database name.'
  DB_ROW_NAME=$ROW_VALUE
  row_default "$app" DB_USER "$user" false 'Application MySQL account, provisioned during platform setup.'
  DB_ROW_USER=$ROW_VALUE
  # Generate a password only when neither canonical nor migrated credentials exist.
  db_row_read "$app" DB_PASSWORD
  password=${ROW_VALUE:-${password:-$(secret)}}
  row_default "$app" DB_PASSWORD "$password" true 'Literal MySQL password for DB_USER; provisioned from this same value. Never URL-encode it.'
  DB_ROW_PASSWORD=$ROW_VALUE
  DB_ROW_ARGS=(-e DB_HOST="$DB_ROW_HOST" -e DB_PORT="$DB_ROW_PORT" -e DB_NAME="$DB_ROW_NAME" -e DB_USER="$DB_ROW_USER" -e DB_PASSWORD="$DB_ROW_PASSWORD")
}

seed_runtime_database_settings() { # MySQL host as AidaAdmin reaches it
  # OfficePulse runs on the PBX host, not on the platform Docker network.
  database_rows aida-pbx "lsdb.$PARENT_DOMAIN" aidacalls_db aida_runtime
  AIDA_RUNTIME_DB_ARGS=("${DB_ROW_ARGS[@]}")
  AIDA_RUNTIME_DB_USER=$DB_ROW_USER
  local runtime_name=$DB_ROW_NAME runtime_user=$DB_ROW_USER
  database_rows aida-pbx-reader "$1" "$runtime_name" aidaadmin_ro aida-admin OFFICEPULSE_RUNTIME_DATABASE_URL
  [ "$DB_ROW_NAME" = "$runtime_name" ] || die 'aida-pbx/DB_NAME and aida-pbx-reader/DB_NAME must match'
  [ "$DB_ROW_USER" != "$runtime_user" ] || die 'OfficePulse and AidaAdmin runtime reader must use distinct DB_USER accounts'
  AIDA_READER_DB_USER=$DB_ROW_USER
  AIDA_READER_DB_ARGS=(-e READER_DB_NAME="$DB_ROW_NAME" -e READER_DB_USER="$DB_ROW_USER" -e READER_DB_PASSWORD="$DB_ROW_PASSWORD")
}

seed_aida_database_settings() {
  database_rows aida-admin "$1" aida_admin_db aida_admin_app aida-admin AIDA_ADMIN_DATABASE_URL
  AIDA_ADMIN_DB_ARGS=("${DB_ROW_ARGS[@]}")
  local admin_user=$DB_ROW_USER
  seed_runtime_database_settings "$1"
  [[ $admin_user != "$AIDA_RUNTIME_DB_USER" && $admin_user != "$AIDA_READER_DB_USER" ]] || die "AidaAdmin store, runtime writer and runtime reader must use distinct DB_USER accounts"
}

provision_aida_databases() { # ADMIN_HOST ROOT_PASSWORD
  # The DB_* input contract changed: fetch the selected branch scripts instead of
  # accidentally invoking an older application checkout on the database host.
  repo_script AidaAdmin "" db-users.sh "${AIDA_ADMIN_DB_ARGS[@]}" \
    -e MYSQL_ADMIN_HOST="$1" -e MYSQL_ADMIN_PORT=3306 -e MYSQL_ADMIN_PASSWORD="$2"
  repo_script OfficePulseAidaIntegration "" db-users.sh \
    "${AIDA_RUNTIME_DB_ARGS[@]}" "${AIDA_READER_DB_ARGS[@]}" \
    -e MYSQL_ADMIN_HOST="$1" -e MYSQL_ADMIN_PORT=3306 -e MYSQL_ADMIN_PASSWORD="$2"
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

  log "Aida databases: scoped DB_* rows and dedicated writer/reader accounts"
  seed_aida_database_settings "$app_db_host"
  provision_aida_databases platform-mysql-local "$root"

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
  ask NOCODB_BASE_URL --nocodb-base-url "NocoDB public URL" "https://nocodb.$PARENT_DOMAIN"
  ask MYSQL_PUBLISH --mysql-publish "MySQL listen address (use 0.0.0.0:3306 for remote hosts)" 127.0.0.1:3306
  ask DATA_DIR --data-dir "Existing MySQL and NocoDB data directory" /var/lib/aidaplatformdb
  local old_data=${SAVED_VALUES[DATA_DIR]:-/var/lib/aidaplatformdb}
  if [ "$(readlink -m "$DATA_DIR")" != "$(readlink -m "$old_data")" ] &&
     { [ -n "$(ls -A "$old_data/mysql" 2>/dev/null)" ] || [ -n "$(ls -A "$old_data/nocodb" 2>/dev/null)" ]; }; then
    die "DATA_DIR contains an existing installation; move its data explicitly before selecting a different directory"
  fi

  log "External networks and the data directories"
  ensure_proxy_network
  ensure_network "$PLATFORM_NETWORK" "$PLATFORM_SUBNET"
  ensure_network "$ECHO_NETWORK" "$ECHO_SUBNET" --internal
  local data_dir=${DATA_DIR:-/var/lib/aidaplatformdb}
  ensure_dir "$data_dir/mysql"
  ensure_dir "$data_dir/nocodb"

  log "$SELF_DIR/.env"
  env_write "$SELF_DIR/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  local key current
  for key in MYSQL_ROOT_PASSWORD NC_AUTH_JWT_SECRET; do
    current=$(env_get "$SELF_DIR/.env" "$key")
    env_set "$SELF_DIR/.env" "$key" "${current:-$(secret)}"
  done
  [ -n "$MYSQL_PUBLISH" ] && env_write "$SELF_DIR/.env" MYSQL_PUBLISH "$MYSQL_PUBLISH"
  [ -n "$DATA_DIR" ] && env_write "$SELF_DIR/.env" DATA_DIR "$DATA_DIR"

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
  if [ -z "${NOCODB_TOKEN:-${SAVED_VALUES[NOCODB_TOKEN]:-}}" ] && { (( YES )) || ! { : < /dev/tty; } 2>/dev/null; }; then
    note "No --nocodb-token: skipping the PlatformConfig rows. Re-run with a token to seed them."
  else
    ask NOCODB_TOKEN --nocodb-token "The installer token"
    log "PlatformConfig"
    ensure_platformconfig
    env_write "$SELF_DIR/.env" NOCODB_INSTALLER_TOKEN "$NOCODB_TOKEN"
    sync_platform_identity
    local current_cidr; current_cidr=$(row_get '*' trustedCIDR)
    ask TRUSTED_CIDR --trusted-cidr "trustedCIDR: the networks the platform's servers sit on" "${current_cidr:-$(default_trusted_cidr)}"
    [ -z "$current_cidr" ] || [ "$current_cidr" = "$TRUSTED_CIDR" ] || row_set '*' trustedCIDR "$TRUSTED_CIDR"
    row_ensure '*' trustedCIDR "$TRUSTED_CIDR" false "IPv4 CIDRs (comma-separated) the platform's servers sit on. One value for the whole platform: every application admits server-to-server callers by it."
    database_accounts
  fi

  env_write "$SELF_DIR/.env" INSTALL_PARENT_DOMAIN "$PARENT_DOMAIN"
  env_write "$SELF_DIR/.env" INSTALL_ENVIRONMENT_NAME "$ENVIRONMENT_NAME"
  local publish; publish=${MYSQL_PUBLISH:-$(env_get "$SELF_DIR/.env" MYSQL_PUBLISH)}
  log "Done. What only you can do:"
  note "1. NocoDB holds every secret the platform has. Block $NOCODB_BASE_URL from the public"
  note "   internet at the reverse proxy, or allow only trustedCIDR."
  note "2. MySQL root password: <configured; hidden>. It is not printed by the installer."
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
  ask NOCODB_BASE_URL --nocodb-base-url "NocoDB public URL" "https://nocodb.$PARENT_DOMAIN"
  ask TOKEN_IDENTITY --token-identity "NocoDB API token for identity"
  ask TOKEN_AIDA_ADMIN --token-aida-admin "NocoDB API token for aida-admin"
  ask TOKEN_AIDA_AGENT --token-aida-agent "NocoDB API token for aida-agent"
  ask TOKEN_ECHO_WEB --token-echo-web "NocoDB API token for echo-web"
  ask TOKEN_ECHO_SERVICE --token-echo-service "NocoDB API token for echo-service"
  ask_installer_token "$TOKEN_IDENTITY"

  log "PlatformConfig"
  ensure_platformconfig
  if (( SAVE_INSTALLER_TOKEN )); then env_write "$SELF_DIR/.env" NOCODB_INSTALLER_TOKEN "$NOCODB_TOKEN"; fi
  sync_platform_identity
  # trustedCIDR is platform-wide; the database host wrote its own networks, and
  # this host's (its Docker subnets and its address, as the other hosts see
  # its calls) must be in it too, or nothing here can call anything.
  local current_cidr proposed_cidr; current_cidr=$(row_get '*' trustedCIDR)
  proposed_cidr=$(cidr_union "$current_cidr" "$(default_trusted_cidr)")
  if [ -n "$current_cidr" ] && [ "$proposed_cidr" != "$current_cidr" ]; then
    note "trustedCIDR ($current_cidr) does not cover this host; proposing to add its networks"
  fi
  ask TRUSTED_CIDR --trusted-cidr "trustedCIDR: the networks the platform's servers sit on" "${current_cidr:-$proposed_cidr}"
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
  db_default=$(row_get echo DB_HOST)
  [ -n "$db_default" ] || db_default=$(row_get aida-admin DB_HOST)
  db_default=${db_default:-${SAVED_VALUES[DB_HOST]:-}}
  if [ -z "$db_default" ] && docker container inspect platform-mysql-local >/dev/null 2>&1; then db_default=platform-mysql-local; fi
  db_default=${db_default:-lsdb.$PARENT_DOMAIN}
  SAVED_VALUES[DB_HOST]=$db_default
  ask DB_HOST --db-host "MySQL host as the applications reach it" "$db_default"
  [ "$DB_HOST" = platform-mysql-local ] && db_local=1
  if ! (( db_local )) && ! timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/3306"' bash "$DB_HOST" 2>/dev/null; then
    note "MySQL at $DB_HOST:3306 is not reachable from this host. On the database host, MySQL must"
    note "listen beyond loopback (MYSQL_PUBLISH=0.0.0.0:3306 in its AidaPlatformDB/.env, then"
    note "docker compose up -d; firewall it to trustedCIDR) and $DB_HOST must resolve to it."
    (( DRY )) || die "cannot reach $DB_HOST:3306"
  fi
  # The database host created every account and left the passwords in the rows,
  # so nothing is asked here. Without those rows (a database host set up before
  # that step existed) the accounts are created from here with root instead.
  local accounts_done=0 aida_accounts_done=0 admin_user admin_pw
  if aida_database_accounts_ready; then aida_accounts_done=1; fi
  admin_pw=$(row_get echo MYSQL_ADMIN_PASSWORD)
  if [ -n "$admin_pw" ]; then
    admin_user=$(row_get echo MYSQL_ADMIN_USER); admin_user=${admin_user:-echo_admin}; accounts_done=1
    note "MySQL accounts exist (created by 'install.sh database'); Echo's jobs run as $admin_user"
  else
    admin_user=root
    if (( db_local )); then saved_env MYSQL_ADMIN_PASSWORD "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD; fi
    [ -n "$MYSQL_ADMIN_PASSWORD" ] || note "The database host has not created the applications' accounts (re-run 'install.sh database' there, or give its MYSQL_ROOT_PASSWORD from AidaPlatformDB/.env here, used once and kept only in echo/.env for Echo's jobs)."
    ask MYSQL_ADMIN_PASSWORD --mysql-admin-password "MySQL root password on $DB_HOST"
    admin_pw=$MYSQL_ADMIN_PASSWORD
  fi

  if ! (( aida_accounts_done )); then
    if (( db_local )); then saved_env MYSQL_ADMIN_PASSWORD "$SELF_DIR/.env" MYSQL_ROOT_PASSWORD; fi
    note "Aida database accounts need provisioning; use this host's MySQL root once, or run 'install.sh database' on the database host first."
    ask MYSQL_ADMIN_PASSWORD --mysql-admin-password "MySQL root password on $DB_HOST"
  fi
  # Always migrate/seed rows, including upgrades where Echo's accounts already exist.
  seed_aida_database_settings "$DB_HOST"

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

  log ".env files (Enter keeps existing values; selected replacements are saved)"
  env_apply "$DIR/identity/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_apply "$DIR/identity/.env" NOCODB_API_TOKEN "$TOKEN_IDENTITY"
  env_apply "$DIR/aida/AidaAdmin/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_apply "$DIR/aida/AidaAdmin/.env" NOCODB_API_TOKEN "$TOKEN_AIDA_ADMIN"
  env_apply "$DIR/aida/AidaAgent/.env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_apply "$DIR/aida/AidaAgent/.env" NOCODB_API_TOKEN "$TOKEN_AIDA_AGENT"
  local echo_env="$DIR/echo/.env"
  env_apply "$echo_env" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_apply "$echo_env" ECHO_WEB_NOCODB_API_TOKEN "$TOKEN_ECHO_WEB"
  env_apply "$echo_env" ECHO_SERVICE_NOCODB_API_TOKEN "$TOKEN_ECHO_SERVICE"
  env_set "$echo_env" ECHO_NETWORK "$ECHO_NETWORK"
  env_set "$echo_env" ECHO_MEDIA_VOLUME echo-media-data
  env_set "$echo_env" ECHO_SERVICE_LOGS_VOLUME echo-service-logs
  # DB_HOST seeds missing coordinates; never redirect existing Echo jobs while
  # the applications still use their preserved PlatformConfig database host.
  local echo_db_host; echo_db_host=$(row_get echo DB_HOST)
  env_set "$echo_env" ECHO_DB_HOST "${echo_db_host:-$DB_HOST}"
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
  local client_secret identity_db_password
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
  fi

  # Everything else the applications need before their first start.
  local carrier
  for carrier in BANDWIDTH TYCHRON; do
    row_ensure echo-service "${carrier}_WEBHOOK_BASIC_USER" "echo-webhook-$ENVIRONMENT_NAME" false "$carrier webhook Basic Auth username; callers inside trustedCIDR are admitted without it."
    row_ensure echo-service "${carrier}_WEBHOOK_BASIC_PASS" "$(secret)" true "$carrier webhook Basic Auth password; takes effect within 30 seconds."
  done
  row_ensure aida-admin SESSION_SECRET "$(secret)" true "Cookie-signing secret for AidaAdmin's own browser sessions."
  row_ensure aida-admin PUBLIC_BASE_URL "https://aida-admin.$PARENT_DOMAIN" false "Public origin of AidaAdmin; builds the OAuth redirect_uri and the /id/events webhook URL."
  row_ensure aida-admin ID_BASE_URL "https://identity.$PARENT_DOMAIN" false "Identity's public origin as AidaAdmin calls it. Scoped to aida-admin on purpose: OfficePulse refuses this key in *, aida and aida-pbx."
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
    note "echo_web and echo_service are created by the Echo environment's own jobs at deploy"
  fi
  if ! (( aida_accounts_done )); then
    log "Provisioning AidaAdmin, OfficePulse runtime, and the read-only runtime account"
    provision_aida_databases "$DB_HOST" "$MYSQL_ADMIN_PASSWORD"
  fi

  if (( NO_DEPLOY )); then log "--no-deploy: stopping before build and start (AidaAdmin's NocoDB tables are created at deploy)"; else
    log "Building and starting"
    compose_up "$DIR/identity"
    # AidaAdmin owns four tables in the PlatformConfig base (aida_tbl_*); its
    # runtime never creates them. Its own bootstrap CLI, run from the image
    # with the .env token, creates what is missing and adds missing columns —
    # additive, so safe on every run — before the application starts.
    log "AidaAdmin's NocoDB tables (nocodb upgrade, from its image)"
    export_stamp "$DIR/aida/AidaAdmin"
    run docker compose --project-directory "$DIR/aida/AidaAdmin" run --rm --no-deps aida-admin node server/dist/nocodb/cli.js upgrade
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
  prereqs git node npm rsync jq openssl curl
  if ! systemctl is-active --quiet asterisk 2>/dev/null; then
    note "Asterisk is not running on this host (systemctl is-active asterisk). OfficePulse needs it; continuing anyway."
  fi
  ask_parent_domain
  ask NOCODB_BASE_URL --nocodb-base-url "NocoDB public URL" "https://nocodb.$PARENT_DOMAIN"
  ask TOKEN_OFFICEPULSE --token-officepulse "NocoDB API token for officepulse"
  ask_installer_token "$TOKEN_OFFICEPULSE"
  ensure_platformconfig
  if (( SAVE_INSTALLER_TOKEN )); then env_write "$SELF_DIR/.env" NOCODB_INSTALLER_TOKEN "$NOCODB_TOKEN"; fi
  if ! has_database_password aida-pbx || ! has_database_password aida-pbx-reader; then
    die "Runtime database accounts are not configured: run 'install.sh database' or 'install.sh apps' first"
  fi
  seed_runtime_database_settings "${DB_HOST:-lsdb.$PARENT_DOMAIN}"
  # What this host can derive for OfficePulse; the PBX-specific rows (its
  # Asterisk realtime database, ARI, the LiveKit SIP host) are its operator's.
  local env_name; env_name=$(row_get '*' ENVIRONMENT_NAME); env_name=${env_name:-${ENVIRONMENT_NAME:-dev}}
  row_ensure aida-pbx OFFICEPULSE_INSTANCE_ID "officepulse-$env_name" false "PBX instance wire name (pbxInstanceId) this OfficePulse serves."
  row_ensure aida-pbx OPS_PUBLIC_URL "https://officepulse-admin.$PARENT_DOMAIN" false "Public origin of the operations UI."
  row_ensure aida-pbx OPS_API_URL "https://officepulse-api.$PARENT_DOMAIN" false "Public origin of the private API as the other applications call it."
  clone_or_update OfficePulseAidaIntegration "$DIR/OfficePulseAidaIntegration"
  local env_file=$OFFICEPULSE_ENV_FILE
  log "$env_file"
  run mkdir -p "$(dirname "$env_file")"
  env_set "$env_file" NODE_ENV production
  env_apply "$env_file" NOCODB_BASE_URL "$NOCODB_BASE_URL"
  env_apply "$env_file" NOCODB_API_TOKEN "$TOKEN_OFFICEPULSE"
  note "Every other OfficePulse value is an aida-pbx/* row (its README lists them); the service reads them at start."
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
  if ! (( DRY )) && [ "${INSTALL_UPDATED:-}" != 1 ] && [ -n "$current" ] && "${g[@]}" fetch -q --prune origin 2>/dev/null; then
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
  database|apps|officepulse|all)
    load_saved_inputs
    load_saved_platform_inputs
    ;;
esac

case $PHASE in
  database) phase_database ;;
  apps) phase_apps ;;
  officepulse) phase_officepulse ;;
  all) phase_database; phase_apps ;;
  migrate-data) phase_migrate_data ;;
esac
