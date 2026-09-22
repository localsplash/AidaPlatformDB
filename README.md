# EchoDatabase

Echo owns the active messaging/media/carrier schema in `init/*.sql`.
Identity owns users, tenants, memberships, sessions and tenant-number access;
PlatformConfig owns runtime settings.

This repository also ships everything an environment needs to bring its own
MySQL up to date and let the apps in:

- `scripts/migrate.sh`: the ordered upgrade runner ([Upgrading a database](#upgrading-a-database))
- `scripts/db-users.sh`: the `echo_web` and `echo_service` accounts and their grants ([Database users](#database-users))
- `compose.yaml`: both as one-shot jobs an environment `include:`s ([Running in an environment](#running-in-an-environment))

## Disposable Dev retirement

The current Dev decision intentionally deletes obsolete configuration and local
authentication/provenance data. No backup, rollback copy or preservation window
is required for this cleanup. Deploy the matching EchoWeb/EchoService revisions
with environment-provided NocoDB credentials first, then apply
`init/013_retire_legacy_configuration_and_auth.sql`.

The migration drops exactly these tables, with foreign-key enforcement kept on:

- `echo_tbl_Settings`
- `echo_tbl_PlatformOrgMap`, `echo_tbl_PlatformUserMap`
- `auth_tbl_Identity`, `auth_tbl_Membership`
- `auth_tbl_Session`, `auth_tbl_SsoNonce`
- `auth_tbl_User`, `auth_tbl_Org`

Child tables are dropped before their parents; `DROP TABLE IF EXISTS` allows
safe repeat execution after an interrupted run. No `sms_*` table/routine or
`echo_tbl_SchemaMigration` ledger is removed. Their data is still in active use.
No Identity `platform_db` or OfficePulse/Asterisk vendor object is changed here.

The old init files 005–009 and 012 are removed, together with the unused mapping
importer, so a fresh database never recreates obsolete objects. The migration
runner's ledger records filenames, not checksums; old ledger rows may remain as execution
history, and existing databases receive the new numbered 013 migration. There
is no technical dependency requiring the deleted seed files to stay in `init/`.

Before applying the migration, inspect the target database's foreign keys and
stored routines for unexpected references to the listed objects. Current source
has no active consumer: EchoWeb's unused legacy helper/import scripts are removed,
EchoService and EchoWeb read only PlatformConfig, and messaging schema foreign
keys reference only messaging/carrier objects. Stop legacy images before cleanup.

Track exact deployed versions, applied SQL, table absence, startup and tenant
access checks in [issue #8](https://github.com/localsplash/EchoDatabase/issues/8).
This supersedes the earlier preservation and rollback-window plan.

## Validation

EchoWeb's `src/platform.integration.test.ts`, with this checkout provided as
`ECHO_DATABASE_SOURCE` and a disposable MySQL 8.4 `TEST_DB_URL`, initializes the
complete current fresh schema and exercises a messaging routine. It then creates
populated legacy tables with foreign keys, applies migration 013 twice, and
checks table removal, active messaging/ledger retention, and central session
access without local auth/mapping tables. It recreates only `echo_platform_test`.

## Upgrading a database

MySQL loads `init/` only into an empty data directory, so a file added later
never reaches an existing database by itself. `scripts/migrate.sh` applies the
files in order against the database as it is, and records each one in
`echo_tbl_SchemaMigration` once it succeeds. Every later run skips recorded
files, so it is safe on every deploy. The files are not idempotent; the ledger
is the whole safety mechanism.

A database that has the schema but no ledger (initialised before the runner
existed) is baselined: every current file is recorded as applied without being
run, and the runner says so loudly. An empty database gets every file applied
in order. The runner moved here from EchoOrchestrator unchanged, so ledgers it
wrote carry on as they are.

It needs MySQL admin rights (`DB_HOST`, `DB_USER`, `MYSQL_PWD`,
`MYSQL_DATABASE`, `MIGRATIONS_DIR`).

## Database users

EchoWeb and EchoService each connect as their own account, created and kept in
line by `scripts/db-users.sh`:

| Account | Grants |
|---|---|
| `echo_web` | `SELECT` on `echo_db`. EchoWeb only reads. |
| `echo_service` | `SELECT` on `echo_db`, plus `EXECUTE` on its stored procedures, which are EchoService's whole write interface. No table-level writes. |

`ECHO_DB_ACCESS` picks how much EchoService may do in an environment:

- `read-write` (default): `EXECUTE` on every procedure.
- `read-only`: `EXECUTE` only on the `*_GET` procedures, looked up when the
  script runs. Nothing can be sent, saved or deleted.

The script is idempotent. It creates missing accounts, sets the passwords it is
given (so re-running with a new value rotates it), revokes everything and grants
exactly the above. Run it after the migrations, since the read-only grants name
routines. Accounts are created for any host (`'%'`); which networks can reach
MySQL is the environment's decision.

The passwords are whatever the environment gives each app as `DB_PASSWORD`;
keep them wherever the environment keeps that value (for example the host's
`.env` next to its Compose file) and pass the same values here.

The single full-rights `echo_app` account that `MYSQL_USER` used to create is
retired. An environment still running on it should create these two accounts,
move each app's `DB_USER`/`DB_PASSWORD` over, then drop `echo_app`.

## Running in an environment

An environment's own Compose file includes `compose.yaml`:

```yaml
include:
  - EchoDatabase/compose.yaml
```

It adds two one-shot jobs that run against the environment's MySQL and exit:
`echo-migrate`, then `echo-db-users`. Their values come from the environment
(see `.env.example`): `ECHO_DB_NETWORK` and `ECHO_DB_HOST` to reach MySQL,
`MYSQL_ADMIN_PASSWORD`, the two app passwords, and `ECHO_DB_ACCESS`. Make
EchoService and EchoWeb wait on them with `condition:
service_completed_successfully` if a deploy should stop when either fails. Or
run them by hand:

```bash
docker compose -f EchoDatabase/compose.yaml --env-file /path/to/env up
```

## Local development

`docker compose -f compose.dev.yaml up -d` creates a throwaway MySQL and applies
the current `init/` files to its empty volume. Running `compose.yaml` against it
on the `echo-db-dev` network then baselines the ledger and creates the app
accounts, exactly as in an environment (commands in `compose.dev.yaml`).
Application DB coordinates stay deployment bootstrap; EchoMedia
still needs only its port and media mount path. Asterisk/OfficePulse own extensions,
queues, memberships and applied DID routes; POC PBX reads use its integration API.
