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
   is — `platform_db`/`identity`, `aida_admin_db`/`aida_admin_app`,
   `echo_db` (schema applied) with `echo_web`, `echo_service` and
   `echo_admin`, and OfficePulse's `aidacalls_db` with `aida_runtime` and the
   read-only `aidaadmin_ro` — using each application's own
   `scripts/db-users.sh`, and writes the generated passwords to the rows the
   applications read (`identity/DB_PASSWORD`,
   `aida-admin/AIDA_ADMIN_DATABASE_URL`, `echo-web/DB_PASSWORD`,
   `echo-service/DB_PASSWORD`, `echo/MYSQL_ADMIN_PASSWORD`,
   `officepulse/RUNTIME_MYSQL_PASSWORD`,
   `aida-admin/OFFICEPULSE_RUNTIME_DATABASE_URL`). `echo_admin` has all rights on `echo_db`
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
5. Builds and starts everything, then prints the reverse-proxy hosts to create
   and what is still yours to fill in: Identity's OAuth provider credentials
   (`/setup` in a browser claims the instance), the `aida/LIVEKIT_*` rows, and
   carrier credentials.

### c) The PBX host — `./install.sh officepulse`

Requires Asterisk running on that host and Node 22. Clones
`OfficePulseAidaIntegration`, writes its `/etc/aida-integration/env`
(`NOCODB_BASE_URL`, `NOCODB_API_TOKEN`), seeds the `officepulse` rows it can
derive (`OFFICEPULSE_INSTANCE_ID`, `OPS_PUBLIC_URL`, `OPS_API_URL`), lists the
ones only this host's operator knows (its Asterisk realtime database, ARI,
how it reaches the platform MySQL, the LiveKit SIP host — see that
repository's README) and runs its own `scripts/install.sh`. Its database
and accounts were created by the database host.

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
