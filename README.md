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

That clones this repository into `/opt/local/AidaPlatformDB` (`--dir` moves the
root) and continues from the checkout, so every host — database, application,
PBX — starts the same way and ends up with the same folder. From an existing
checkout, `./install.sh <phase>` does the same.

Every repository is taken from its `main` branch; `--branch dev` takes `dev`
(and the one-liner's URL should then name `dev` too).
Values not given as flags are asked for; `--yes` makes missing values an error
instead. `--dry-run` prints what would happen. Re-running is safe: existing
`.env` values, rows with a value and accounts are kept, and only what is missing
is created.

### a) The database host — `./install.sh database`

1. Creates the external networks and volumes, writes `.env` (generated
   `MYSQL_ROOT_PASSWORD` and `NC_AUTH_JWT_SECRET`, `NOCODB_BASE_URL` =
   `https://nocodb.X.TLD`) and starts MySQL and NocoDB.
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

When it finishes it reminds you that NocoDB holds every secret the platform
has: block it from the public internet at the reverse proxy, or allow only
`trustedCIDR`.

`--mysql-publish 0.0.0.0:3306` is for a platform whose applications run on
other hosts; they reach MySQL as `lsdb.X.TLD`. Firewall that port to
`trustedCIDR`.

### b) The application host — `./install.sh apps`

Recommended on its own host; the same host as the database also works (the
apps then reach MySQL by container name).

1. Ensures `npm_network`, `platform-local`, `echo-local` and the data volumes.
2. Clones `identity`, `AidaAdmin`, `AidaAgent`, `EchoWeb`, `EchoService` and
   `EchoMedia` under `--dir` (default `/opt/local`), laid out the way the
   compose files expect:

   ```
   /opt/local/AidaPlatformDB      this repo (echo/ is included by the Echo environment)
   /opt/local/identity
   /opt/local/aida/AidaAdmin
   /opt/local/aida/AidaAgent
   /opt/local/echo                the Echo environment (from EchoWeb/deploy/environment)
     ├── EchoWeb  EchoService  EchoMedia
     └── compose.yaml  web.host.yaml  service.host.yaml  deploy.sh  .env
   ```
3. Writes each `.env` with `NOCODB_BASE_URL` and that application's token, and
   Echo's with the generated MySQL passwords its jobs create.
4. Creates the MySQL accounts (`identity`, `aida_admin_app`; Echo's are created
   by its own jobs at deploy) and seeds the rows the applications need to
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
(`NOCODB_BASE_URL`, `NOCODB_API_TOKEN`) and runs its own `scripts/install.sh`.
Its settings are the `officepulse` rows (see that repository's README).

## Day-to-day

- Deploy the database layer with `docker compose up -d` in this folder; each
  application with its own folder's `deploy.sh` or Compose file.
- Upgrading `echo_db` is a normal Echo deploy: the `echo-migrate` job applies
  new `echo/init/*.sql` files first ([echo/README.md](echo/README.md)).
- Rotating a password: change the row (or Echo's `.env`) and re-run the
  owning `db-users.sh`; they converge.
