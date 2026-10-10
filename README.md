# AidaPlatformDB

The platform's database layer and the installer that stands a platform up.

| What | Where |
| --- | --- |
| The shared **MySQL** and **NocoDB** every application uses | [`compose.yaml`](compose.yaml), [`.env.example`](.env.example) — deployed on the database host |
| The **echo_db** schema, its migration runner and the `echo_web` / `echo_service` accounts | [`echo/`](echo/) — one-shot jobs an Echo environment `include:`s |
| The **installer**: prerequisites, clones, `.env` files, database accounts, PlatformConfig rows, first deploy | [`install.sh`](install.sh) |

NocoDB holds the `PlatformConfig` base. Its `cfg_tbl_Setting` table is the only
settings source for every application (`app` scope + `settingKey` +
`settingValue`, blank = unset). Each application's `.env` states just how to
reach that store: `NOCODB_BASE_URL` and its own `NOCODB_API_TOKEN`. Databases,
accounts and grants belong to the application that owns them — Identity,
AidaAdmin and OfficePulse each ship a `scripts/db-users.sh`, and Echo's live in
[`echo/scripts`](echo/scripts). Nothing in this repo invents a value for
another app.

## Installing a platform

Prerequisites on every host: Linux, Docker with Compose v2, `git`, `curl`, `jq`,
`openssl`, and a reverse proxy (Nginx Proxy Manager) on a Docker network named
`npm_network` that terminates TLS for `*.X.TLD`. The installer refuses to guess a
domain: `X.TLD` is whatever domain this platform is deployed under.

```sh
curl -fsSL https://raw.githubusercontent.com/localsplash/AidaPlatformDB/main/install.sh \
  | bash -s -- database          # or: apps, officepulse, all; --help for the flags
```

That clones this repository into `/opt/AidaPlatformDB` (`--dir` moves the
root) and continues from the checkout, so every host — database, application,
PBX — starts the same way and ends up with the same folder. From an existing
checkout, `./install.sh <phase>` does the same, with the install root being
that checkout's parent.

Every repository is taken from the branch the AidaPlatformDB checkout is on
(`main` for the one-liner unless `--branch` says otherwise), so a `dev`
checkout installs `dev` everywhere; a repository that has no such branch is
taken from its default branch, and the installer says so. The one-liner's URL
should name the same branch. A checkout that is behind its branch updates
itself and starts over, so a stale `install.sh` never runs. Passwords, secrets
and tokens are typed without echo.
Values not given as flags are asked for; `--yes` makes missing values an error
instead. `--dry-run` prints what would happen. Re-running is safe: existing
`.env` values, rows with a value and accounts are kept, and only what is missing
is created.

### a) The database host — `./install.sh database`

The database host is any Linux host with Docker: a dedicated VM in production,
or the same host as the applications on a small platform. Either way MySQL and
NocoDB run as the two pinned containers in `compose.yaml`; there is no native
(package) install, and the only prerequisites are the ones above. A dedicated VM
differs in one flag, `--mysql-publish`, so the application hosts can reach MySQL
as `lsdb.X.TLD`.

1. Creates the external networks and the data directories
   (`/var/lib/aidaplatformdb/mysql` and `/nocodb`, or `--data-dir`), writes
   `.env` (generated `MYSQL_ROOT_PASSWORD` and `NC_AUTH_JWT_SECRET`,
   `NOCODB_BASE_URL` = `https://nocodb.X.TLD`) and starts MySQL and NocoDB.
2. Stops and asks you to **claim NocoDB** in a browser: the first sign-up
   becomes its super admin. Then create a base named `PlatformConfig`, and
   inside it one API token per application: `installer`, `identity`,
   `aida-admin`, `aida-agent`, `echo-web`, `echo-service`, and `officepulse`
   if you run it. (NocoDB binds an API token to the base it is created in —
   a token can create another base but cannot work inside it — so the base
   comes first and the tokens are made in it.)
3. With the installer token, creates the `cfg_tbl_Setting` table in that base
   (found by name; nothing is recreated) and seeds the global rows:
   `ENVIRONMENT_NAME`, `PARENT_DOMAIN`, `trustedCIDR`.
4. Creates every application's database and MySQL account here, where root
   is — `platform_db`/`identity`, `aida_admin_db`/`aida_admin_app`, and
   `echo_db` (schema applied) with `echo_web`, `echo_service` and
   `echo_admin` — using each application's own `scripts/db-users.sh`, and
   writes the generated passwords to the rows the applications read
   (`identity/DB_PASSWORD`, `aida-admin/DB_PASSWORD`,
   `echo-web/DB_PASSWORD`, `echo-service/DB_PASSWORD`,
   `echo/MYSQL_ADMIN_PASSWORD`). `echo_admin` has all rights on `echo_db`
   and `CREATE USER`, nothing more: it is what the Echo environment's
   deploy-time migration and account jobs run as, so the MySQL root password
   never leaves this host.
5. Prints the MySQL root password (it is also `MYSQL_ROOT_PASSWORD` in
   `.env`) and what only you can do next.

When it finishes it reminds you that NocoDB holds every secret the platform
has: block it from the public internet at the reverse proxy, or allow only
`trustedCIDR`.

When the applications will run on other hosts, answer yes to the question
(or pass `--mysql-publish 0.0.0.0:3306`): MySQL then listens beyond loopback,
and they reach it as `lsdb.X.TLD`, which you point at this host's private
address. Firewall that port to `trustedCIDR`.

The MySQL root password lives in this host's `.env` and nowhere else — not in
NocoDB, where every application's token could read it — and nothing else
needs it.

### b) The application host — `./install.sh apps`

Recommended on its own host; the same host as the database also works (the
apps then reach MySQL by container name).

1. Ensures `npm_network`, `platform-local`, `echo-local` and the data volumes.
2. Clones `identity`, `AidaAdmin`, `AidaAgent`, `EchoWeb`, `EchoService` and
   `EchoMedia` under the install root (this checkout's parent, or `--dir`), laid out the way the
   compose files expect:

   ```
   /opt/AidaPlatformDB      this repo (echo/ is included by the Echo environment)
   /opt/identity
   /opt/aida/AidaAdmin
   /opt/aida/AidaAgent
   /opt/echo                the Echo environment (from EchoWeb/deploy/environment)
     ├── EchoWeb  EchoService  EchoMedia
     └── compose.yaml  web.host.yaml  service.host.yaml  deploy.sh  .env
   ```
3. Writes each `.env` with `NOCODB_BASE_URL` and that application's token, and
   Echo's with the generated MySQL passwords its jobs create.
4. Checks MySQL is reachable, then takes the account passwords the database
   host left in the rows — no MySQL credential is asked for; Echo's `.env`
   gets `echo_admin` for its jobs. (A database host set up before that step
   existed is the fallback: the accounts are created from here with its root
   password, asked for once.) Then it seeds the rows the applications need to
   start: database coordinates, the shared `IDENTITY_CLIENT_SECRET`, session
   and webhook secrets, the public URLs derived from `PARENT_DOMAIN`
   (`https://identity.X.TLD`, `https://aida-admin.X.TLD`,
   `https://officepulse-api.X.TLD`) and the voice model defaults.
5. Builds and starts everything — including AidaAdmin's four NocoDB tables
   (`aida_tbl_TenantProfile`, `aida_tbl_AssistantProfile`,
   `aida_tbl_ProfileAssignment`, `aida_tbl_Appearance`), created with its own
   `nocodb upgrade` from its image before it starts; the step is additive, so
   re-running is safe — then prints the reverse-proxy hosts to create
   and what is still yours to fill in: Identity's OAuth provider credentials
   (`/setup` in a browser claims the instance), the `aida/LIVEKIT_*` rows, and
   carrier credentials.

### c) The PBX host — `./install.sh officepulse`

Requires Asterisk running on that host and Node 22. Clones
`OfficePulseAidaIntegration`, writes its `/etc/aida-integration/env`
(`NOCODB_BASE_URL`, `NOCODB_API_TOKEN`) and runs its own `scripts/install.sh`.
Its settings are the `aida-pbx` rows (see that repository's README).

## Day-to-day

- The database layer is `docker compose up -d` in this folder on the database
  host, whether that host is a dedicated VM or shared with the applications.
  Images are pinned by digest, so a recreate never upgrades MySQL or NocoDB by
  accident; upgrading is a deliberate edit of the digest, then `up -d`.
- A host set up before the data moved onto the host (MySQL and NocoDB on the
  `platform-mysql-data` / `platform-nocodb-data` volumes) runs
  `./install.sh migrate-data` once: it stops the pair, copies the volumes to
  `DATA_DIR` with ownership intact, restarts on the host directories, lists the
  databases it now serves, and removes the volumes. `install.sh database`
  refuses to start while data is still in a volume and the directory is empty,
  and `migrate-data` recognises a fresh, empty instance that was started on the
  empty directory by mistake, sets it aside (`…/mysql.empty-<stamp>`) and puts
  the volume's data in its place.
- The data is on the host, not in Docker: MySQL's data directory is
  `DATA_DIR/mysql` and NocoDB's store (the PlatformConfig base, its rows, users
  and API tokens in `noco.db`) is `DATA_DIR/nocodb`, `DATA_DIR` being
  `/var/lib/aidaplatformdb` unless `.env` says otherwise. Containers and images
  hold nothing; rebuilding or recreating them never touches these paths, and
  no Compose command removes a bind mount. Back up that path and the `.env`
  files (they hold the root password and every app's NocoDB token). A
  consistent dump is
  `docker exec platform-mysql-local mysqldump --all-databases --single-transaction --routines`
  with the root password from `.env`.
- Each application is deployed from its own folder: `deploy.sh` for the Echo
  environment, `docker compose up -d --build` (or `docker-container-control
  deploy <name>`) for the others.
- Upgrading `echo_db` is a normal Echo deploy: the `echo-migrate` job applies
  new `echo/init/*.sql` files first ([echo/README.md](echo/README.md)).
- Rotating a password: change the row (or Echo's `.env`) and re-run the
  owning `db-users.sh`; they converge.



## Re-running the installer

Run the same phase from the same checkout/install root. Existing settings are
reviewed rather than requested from scratch:

```sh
./install.sh apps --branch dev
./install.sh database --branch dev
# On the PBX host:
./install.sh officepulse --branch dev
```

Normal prompts show the current value in brackets. Press **Enter** to keep it,
or type a replacement. Password/token prompts show only
`[configured; Enter to keep, or type a replacement; not echoed]`.
Neither the old secret nor the replacement is printed. Explicit flags and
nonempty environment variables take precedence without an extra prompt.
`--yes` uses saved values/defaults; an essential value with neither still fails.

The installer discovers the existing application `.env` files under `--dir`,
the platform `.env`, and OfficePulse's `/etc/aida-integration/env`. It reads these
as data, never executes them. When the saved NocoDB endpoint is reachable,
PlatformConfig supplies the current parent domain and environment name before
prompting. Otherwise local hints are used, then reconciled against the real rows
after NocoDB is available. The database phase stores its validated installer
token as `NOCODB_INSTALLER_TOKEN` in the platform `.env`, not in PlatformConfig.
`INSTALL_PARENT_DOMAIN` and `INSTALL_ENVIRONMENT_NAME` are offline hints only;
the existing platform rows remain authoritative for defaults.

Selected bootstrap replacements (such as an application API token or the public
NocoDB URL) are actually written, rather than silently ignored because a file
already exists. Changed files are replaced atomically with mode 600; unrelated
entries and comments remain. Keeping a shared URL also keeps any existing
per-application URL overrides. These bootstrap inputs are single-line values.

Saved `DATA_DIR` and `MYSQL_PUBLISH` are reused and displayed on database-host
reruns. Selecting a different data directory while the old one contains data
fails before writing settings or starting containers; it is not a data migration.
MySQL root/JWT secrets and existing application database credentials are kept,
not rotated by this review. Scoped `DB_*` rows are displayed (passwords hidden)
and preserved; `--db-host` supplies missing database coordinates, not a mass
rewrite of already-provisioned per-app connections. Credential rotation, database
moves, and a platform domain migration require their own coordinated changes.

`--dry-run` masks complete secret values (including spaces/newlines), makes no
settings writes, and skips the checkout's auto-update. `--no-deploy` still permits
settings/account setup but stops before the application builds/restarts, as before.
Neither option turns the database phase into an offline operation: that phase
normally starts MySQL/NocoDB so it can perform setup; use `--dry-run` to preview it.

Regression tests include real terminal prompts and reruns against temporary files
and a fake settings API; no running deployment is used:

```sh
bash -n install.sh
python3 -m unittest discover -s tests -v
```


## Aida database settings

Database and app setup now seeds the same canonical setting keys in each
connection's own PlatformConfig scope. `DB_PASSWORD` is marked secret and stored
literally (not URL-encoded); `DB_PORT` is optional at runtime and defaults to 3306.

| Scope (`app`) | `DB_NAME` | `DB_USER` | Purpose |
| --- | --- | --- | --- |
| `aida-admin` | `aida_admin_db` | `aida_admin_app` | Admin's writable OAuth state, event receipts and audit store |
| `aida-pbx` | `aidacalls_db` | `aida_runtime` | Runtime writer and schema migrations |
| `aida-pbx-reader` | `aidacalls_db` | `aidaadmin_ro` | Admin's SELECT-only view of runtime state |

`aida-pbx` is the bridge between OfficePulse's Asterisk and Aida's LiveKit agent
(the OfficePulseAidaIntegration service); it was called `officepulse`, and
`aida-pbx-reader` was `aida-admin-runtime`. Every phase that reaches
PlatformConfig renames rows still under the old names in place, keeping their
values; a key present under both names stops the run until one row is deleted.

Every scope also has `DB_HOST`, `DB_PORT`, and `DB_PASSWORD`. The installer uses
AidaAdmin's and OfficePulse's own `scripts/db-users.sh` implementations to create
the databases/accounts and grant the appropriate access. AidaAgent has no SQL
connection and receives no database credentials. Database settings must not be
placed in `aida` or `*`, where another application could inherit them.

The application-host connection defaults to `platform-mysql-local` when local,
or `lsdb.<PARENT_DOMAIN>` when remote. OfficePulse runs on the PBX host, so its
host defaults to `lsdb.<PARENT_DOMAIN>`, never the platform-only Docker name.
Preserved per-app host/port values may describe an existing SSH tunnel. Those
network paths must reach the same physical runtime database; the installer does
not create tunnels or change firewall policy. `MYSQL_ADMIN_HOST` and
`MYSQL_ADMIN_PORT` are provisioning-only overrides for the operator's path.

### Upgrading existing settings

Run setup with the updated `dev` checkouts before restarting the applications:

```sh
./install.sh apps --branch dev
# On a new installation, run the database phase first as usual:
# ./install.sh database --branch dev
```

Only the installer's migration code recognizes the retired
`AIDA_ADMIN_DATABASE_URL`, `OFFICEPULSE_RUNTIME_DATABASE_URL`, and
`RUNTIME_MYSQL_*` rows. It copies their host, port, schema, username and password
into the appropriate `DB_*` rows. Percent-encoded URL credentials are decoded
once; literal canonical passwords, including punctuation/newlines, are preserved.
Nonblank canonical rows take precedence. Re-running is idempotent and does not
rotate existing passwords. Retired rows are left intact for rollback and may be
removed after the updated applications start; no application requires them.

When account credentials are missing, app setup requests MySQL root once to
provision the missing accounts. Echo's existing account rows no longer suppress
Aida account setup. An already-provisioned installation only needs row migration.
The PBX-host phase verifies the runtime accounts exist and migrates their rows
before running OfficePulse's installer. It does not invent database credentials
for an unprovisioned server.

Installer regression tests use a fake settings store, without Docker or MySQL:

```sh
python3 -m unittest discover -s tests -v
```
