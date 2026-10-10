"""Installer reruns against temporary files/fake services; no deployed resources."""
import json
import os
from pathlib import Path
import pty
import select
import signal
import shutil
import subprocess
import tempfile
import time
import unittest

INSTALL = Path(__file__).resolve().parents[1] / 'install.sh'
SOURCE = 'INSTALL_SOURCE_ONLY=1 source "$INSTALL_FILE"\n'


class RerunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'AidaPlatformDB').mkdir()
        self.env = {**os.environ, 'INSTALL_FILE': str(INSTALL), 'TEST_ROOT': str(self.root)}
        for key in ('NOCODB_BASE_URL', 'NOCODB_TOKEN', 'PARENT_DOMAIN', 'ENVIRONMENT_NAME',
                    'DB_HOST', 'MYSQL_PUBLISH', 'DATA_DIR', 'MYSQL_ADMIN_PASSWORD'):
            self.env.pop(key, None)
        self.setup = SOURCE + '''
DIR=$TEST_ROOT; SELF_DIR=$DIR/AidaPlatformDB; PHASE=apps
OFFICEPULSE_ENV_FILE=$DIR/officepulse.env
'''

    def shell(self, body, ok=True):
        result = subprocess.run(['bash', '-c', self.setup + body], env=self.env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def file(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def interactive(self, body, responses):
        """Use a real controlling TTY, including while stdin is /dev/null (curl|bash)."""
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe('bash', ['bash', '-c', self.setup + 'exec </dev/null\n' + body], self.env)
        output = b''
        answered = 0
        deadline = time.monotonic() + 8
        status = None
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if answered < len(responses):
                        marker, value = responses[answered]
                        if marker.encode() in output:
                            os.write(fd, value)
                            answered += 1
                child, status = os.waitpid(pid, os.WNOHANG)
                if child:
                    break
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail('Prompt stalled: ' + output.decode(errors='replace'))
        finally:
            os.close(fd)
            try:
                _, status = os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode(errors='replace'))
        self.assertEqual(answered, len(responses))
        return output.decode(errors='replace')

    def test_secret_enter_keeps_literal_value_without_echo_with_piped_stdin(self):
        out = self.interactive('''
SAVED_VALUES[TOKEN_IDENTITY]='original secret $() %40'
ask TOKEN_IDENTITY --token-identity 'Identity token'
[ "$TOKEN_IDENTITY" = 'original secret $() %40' ]
''', [('Identity token [configured;', b'\n')])
        self.assertIn('Enter to keep', out)
        self.assertNotIn('original secret', out)

    def test_secret_replacement_is_hidden_and_persisted(self):
        self.file('identity/.env', 'NOCODB_API_TOKEN=previous-secret\nKEEP=untouched\n')
        out = self.interactive('''
load_saved_inputs
ask TOKEN_IDENTITY --token-identity 'Identity token'
env_apply "$DIR/identity/.env" NOCODB_API_TOKEN "$TOKEN_IDENTITY"
[ "$(env_get "$DIR/identity/.env" NOCODB_API_TOKEN)" = 'replacement-secret' ]
''', [('Identity token [configured;', b'replacement-secret\n')])
        self.assertNotIn('previous-secret', out)
        self.assertNotIn('replacement-secret', out)
        self.assertIn('NOCODB_API_TOKEN=replacement-secret', (self.root / 'identity/.env').read_text())

    def test_visible_current_default_and_changed_value(self):
        out = self.interactive('''
SAVED_VALUES[DB_HOST]=current-db
ask DB_HOST --db-host 'MySQL host'
[ "$DB_HOST" = changed-db ]
''', [('MySQL host [current-db]:', b'changed-db\n')])
        self.assertIn('[current-db]', out)

    def test_missing_secret_fails_noninteractively_and_eof_aborts(self):
        self.shell('YES=1; ask TOKEN_IDENTITY --token-identity "Identity token"', ok=False)
        self.interactive('''
SAVED_VALUES[TOKEN_IDENTITY]=old-secret
if ( ask TOKEN_IDENTITY --token-identity 'Identity token' ); then exit 1; fi
''', [('Identity token [configured;', b'\x04')])

    def test_yes_uses_saved_values_and_explicit_override_wins(self):
        r = self.shell('''
YES=1; SAVED_VALUES[TOKEN_IDENTITY]=saved-secret
ask TOKEN_IDENTITY --token-identity 'Identity token' generated-fallback
[ "$TOKEN_IDENTITY" = saved-secret ]
TOKEN_IDENTITY=override-secret
ask TOKEN_IDENTITY --token-identity 'Identity token'
[ "$TOKEN_IDENTITY" = override-secret ]
''')
        self.assertNotIn('saved-secret', r.stdout + r.stderr)
        self.assertNotIn('override-secret', r.stdout + r.stderr)

    def test_discovers_all_bootstrap_files_without_executing_them(self):
        self.file('AidaPlatformDB/.env', 'NOCODB_BASE_URL=https://nocodb.example.test\nDATA_DIR=/srv/current\nNOCODB_INSTALLER_TOKEN=installer\nMYSQL_ROOT_PASSWORD=root-secret\n')
        for path, key, value in [
            ('identity/.env', 'NOCODB_API_TOKEN', 'identity-token'),
            ('aida/AidaAdmin/.env', 'NOCODB_API_TOKEN', 'admin-token'),
            ('aida/AidaAgent/.env', 'NOCODB_API_TOKEN', 'agent-token'),
            ('echo/.env', 'ECHO_WEB_NOCODB_API_TOKEN', 'web-token'),
            ('officepulse.env', 'NOCODB_API_TOKEN', 'pbx-token'),
        ]:
            self.file(path, f'{key}={value}\n$(touch "{self.root}/should-not-exist")\n')
        with (self.root / 'echo/.env').open('a') as out:
            out.write('ECHO_SERVICE_NOCODB_API_TOKEN=service-token\nECHO_DB_HOST=existing-db\n')
        self.shell('''
load_saved_inputs
[ "${SAVED_VALUES[PARENT_DOMAIN]}" = example.test ]
[ "${SAVED_VALUES[DATA_DIR]}" = /srv/current ]
[ "${SAVED_VALUES[NOCODB_TOKEN]}" = installer ]
[ "${SAVED_VALUES[MYSQL_ADMIN_PASSWORD]}" = root-secret ]
[ "${SAVED_VALUES[TOKEN_IDENTITY]}" = identity-token ]
[ "${SAVED_VALUES[TOKEN_AIDA_ADMIN]}" = admin-token ]
[ "${SAVED_VALUES[TOKEN_AIDA_AGENT]}" = agent-token ]
[ "${SAVED_VALUES[TOKEN_ECHO_WEB]}" = web-token ]
[ "${SAVED_VALUES[TOKEN_ECHO_SERVICE]}" = service-token ]
[ "${SAVED_VALUES[TOKEN_OFFICEPULSE]}" = pbx-token ]
[ "${SAVED_VALUES[DB_HOST]}" = existing-db ]
''')
        self.assertFalse((self.root / 'should-not-exist').exists())

    def test_env_replacement_preserves_comments_other_keys_and_restricts_permissions(self):
        path = self.file('identity/.env', '# keep comment\nNOCODB_API_TOKEN=old\nKEEP=value\nNOCODB_API_TOKEN=duplicate\n')
        result = self.shell('''
env_write "$DIR/identity/.env" NOCODB_API_TOKEN 'new-$LITERAL#%40= token'
[ "$(env_get "$DIR/identity/.env" NOCODB_API_TOKEN)" = 'new-$LITERAL#%40= token' ]
''')
        text = path.read_text()
        self.assertIn('# keep comment\n', text)
        self.assertIn('KEEP=value\n', text)
        self.assertEqual(text.count('NOCODB_API_TOKEN='), 1)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('new-$LITERAL', result.stdout)

    def test_unchanged_inputs_preserve_bytes_and_per_app_url_overrides(self):
        path = self.file('identity/.env', "NOCODB_API_TOKEN='existing' # keep this\nNOCODB_BASE_URL=http://internal-nocodb:8080\n")
        before = path.read_bytes()
        self.shell('''
SAVED_VALUES[NOCODB_BASE_URL]=https://nocodb.example.test
env_apply "$DIR/identity/.env" NOCODB_API_TOKEN existing
env_apply "$DIR/identity/.env" NOCODB_BASE_URL https://nocodb.example.test
''')
        self.assertEqual(path.read_bytes(), before)

    def test_dry_run_does_not_write_and_redacts_whole_secret_arguments(self):
        path = self.file('identity/.env', 'NOCODB_API_TOKEN=original\n')
        before = path.read_bytes()
        r = self.shell('''
DRY=1
env_write "$DIR/identity/.env" NOCODB_API_TOKEN 'new secret value'
run docker -e 'MYSQL_PWD=secret with spaces' -e $'DB_PASSWORD=secret\\nsecond-line'
run command --api-key 'hidden-cli-token' 'mysql://u:hidden-url-password@host/db'
run mysql -e "ALTER USER u IDENTIFIED BY 'hidden-sql-password'"
''')
        self.assertEqual(path.read_bytes(), before)
        for value in ('new secret value', 'with spaces', 'second-line', 'hidden-cli-token', 'hidden-url-password', 'hidden-sql-password'):
            self.assertNotIn(value, r.stdout + r.stderr)

    def test_row_output_uses_bsecret_and_never_shows_password_values(self):
        r = self.shell('''
ROWS_JSON='[{"Id":1,"app":"*","settingKey":"opaque","settingValue":"stored-hidden-value","bSecret":true}]'
row_ensure '*' opaque ignored false description
DRY=1
row_set '*' opaque replacement-hidden-value
row_set '*' API_KEY hidden-api-key
''')
        for value in ('stored-hidden-value', 'replacement-hidden-value', 'hidden-api-key'):
            self.assertNotIn(value, r.stdout + r.stderr)

    def test_platform_probe_uses_saved_credentials_and_paginates_without_writes(self):
        self.shell('''
SAVED_VALUES[NOCODB_BASE_URL]=https://nocodb.saved.test
SAVED_VALUES[TOKEN_IDENTITY]=saved-token
curl() {
  local url=${*: -1}
  [[ " $* " != *' -X '* && " $* " == *'xc-token: saved-token'* ]] || return 1
  case $url in
    */meta/bases) echo '{"list":[{"title":"PlatformConfig","id":"base"}]}' ;;
    */base/tables) echo '{"list":[{"title":"cfg_tbl_Setting","id":"settings"}]}' ;;
    *offset=0) jq -n '{list:[range(200) | {app:"other",settingKey:"ignore"}]}' ;;
    *offset=200) echo '{"list":[{"app":"*","settingKey":"PARENT_DOMAIN","settingValue":"actual.test"},{"app":"*","settingKey":"ENVIRONMENT_NAME","settingValue":"prod"}]}' ;;
    *) return 1 ;;
  esac
}
load_saved_platform_inputs
[ "${SAVED_VALUES[PARENT_DOMAIN]}" = actual.test ]
[ "${SAVED_VALUES[ENVIRONMENT_NAME]}" = prod ]
''')

    def test_failed_probe_leaves_saved_values_unchanged(self):
        self.shell('''
SAVED_VALUES[NOCODB_BASE_URL]=https://nocodb.saved.test
SAVED_VALUES[TOKEN_IDENTITY]=old-token
SAVED_VALUES[ENVIRONMENT_NAME]=staging
curl() { return 22; }
load_saved_platform_inputs
[ "${SAVED_VALUES[ENVIRONMENT_NAME]}" = staging ]
''')

    def test_rejects_invalid_environment_and_relative_data_path(self):
        self.shell('YES=1; SAVED_VALUES[ENVIRONMENT_NAME]=bad; ask ENVIRONMENT_NAME --environment-name Environment', ok=False)
        self.shell('YES=1; SAVED_VALUES[DATA_DIR]=relative; ask DATA_DIR --data-dir Data', ok=False)

    def database_fixture(self):
        self.file('AidaPlatformDB/.env', f'''NOCODB_BASE_URL=https://nocodb.example.test
INSTALL_PARENT_DOMAIN=example.test
INSTALL_ENVIRONMENT_NAME=staging
MYSQL_ROOT_PASSWORD=root-keep-secret
NC_AUTH_JWT_SECRET=jwt-keep-secret
MYSQL_PUBLISH=127.0.0.1:13306
DATA_DIR={self.root}/existing-data
''')
        self.file('existing-data/mysql/existing-data', 'do not change')
        self.file('existing-data/nocodb/existing-data', 'do not change')
        return '''
PHASE=database; YES=1
prereqs() { :; }; ensure_proxy_network() { :; }; ensure_network() { :; }
docker() { :; }; wait_for() { :; }; unmigrated_volumes() { :; }
secret() { die 'No secret should be generated on an unchanged database rerun'; }
load_saved_inputs
'''

    def test_database_rerun_reuses_data_binding_and_hides_root_password(self):
        fixture = self.database_fixture()
        path = self.root / 'AidaPlatformDB/.env'
        before = path.read_bytes()
        for _ in range(2):
            r = self.shell(fixture + 'phase_database\n')
            self.assertNotIn('root-keep-secret', r.stdout + r.stderr)
            self.assertNotIn('jwt-keep-secret', r.stdout + r.stderr)
            self.assertIn('127.0.0.1:13306', r.stdout)
            self.assertIn(str(self.root / 'existing-data'), r.stdout)
            self.assertEqual(path.read_bytes(), before)

    def test_different_data_directory_is_rejected_before_writes_or_start(self):
        fixture = self.database_fixture()
        path = self.root / 'AidaPlatformDB/.env'
        before = path.read_bytes()
        r = self.shell(fixture + 'DATA_DIR=$DIR/new-empty-data; phase_database\n', ok=False)
        self.assertIn('existing installation', r.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse((self.root / 'new-empty-data').exists())

    def fake_platform(self):
        settings = [('*', 'PARENT_DOMAIN', 'example.test'), ('*', 'ENVIRONMENT_NAME', 'staging'),
                    ('*', 'trustedCIDR', '10.0.0.0/8'), ('echo', 'DB_HOST', 'platform-mysql-local'),
                    ('echo', 'MYSQL_ADMIN_PASSWORD', 'echo-admin-secret'), ('echo', 'MYSQL_ADMIN_USER', 'echo_admin')]
        for app, name, user in [('aida-admin', 'aida_admin_db', 'aida_admin_app'),
                                ('aida-pbx', 'aidacalls_db', 'aida_runtime'),
                                ('aida-pbx-reader', 'aidacalls_db', 'aidaadmin_ro')]:
            settings += [(app, 'DB_HOST', 'platform-mysql-local'), (app, 'DB_PORT', '3306'),
                         (app, 'DB_NAME', name), (app, 'DB_USER', user), (app, 'DB_PASSWORD', app + '-db-secret')]
        self.file('rows.json', json.dumps([dict(Id=i + 1, app=app, settingKey=key, settingValue=value,
                                              bSecret=('PASSWORD' in key))
                                         for i, (app, key, value) in enumerate(settings)]))
        self.file('fake_nc.py', """
import json, sys
from pathlib import Path
path = Path(sys.argv[1]); args = sys.argv[2:]; rows = json.loads(path.read_text())
value = json.loads(args[args.index('--data') + 1])
if '-X' in args and args[args.index('-X') + 1] == 'PATCH':
    for patch in value:
        for row in rows:
            if row['Id'] == patch['Id']: row.update(patch)
else:
    value['Id'] = max([row['Id'] for row in rows] + [0]) + 1
    rows.append(value)
path.write_text(json.dumps(rows))
""")
        return r"""
YES=1; NO_DEPLOY=1; BRANCH=dev
prereqs() { :; }; ensure_proxy_network() { :; }; ensure_network() { :; }; ensure_volume() { :; }
clone_or_update() { mkdir -p "$2"; }
ensure_platformconfig() { TABLE_ID=test; ROWS_JSON=$(cat "$DIR/rows.json"); }
rows_load() { ROWS_JSON=$(cat "$DIR/rows.json"); }
nc() { python3 "$DIR/fake_nc.py" "$DIR/rows.json" "$@"; }
default_trusted_cidr() { echo 10.0.0.0/8; }
proxy_subnet() { echo 10.0.0.0/8; }
docker() { [[ $* == 'container inspect platform-mysql-local' ]]; }
systemctl() { return 0; }
provision_aida_databases() { die 'Unexpected account rotation'; }
secret() { echo generated-fixture-secret; }
"""

    def test_full_apps_phase_reuses_tokens_and_preserves_accounts_on_second_run(self):
        platform = self.fake_platform()
        for app in ('identity', 'aida/AidaAdmin', 'aida/AidaAgent'):
            self.file(app + '/.env', 'NOCODB_BASE_URL=https://nocodb.example.test\nNOCODB_API_TOKEN=keep-app-secret\n')
        self.file('identity/compose.yaml', '')
        self.file('identity/scripts/db-users.sh', '')
        for name in ('compose.yaml', 'web.host.yaml', 'service.host.yaml', 'deploy.sh'):
            self.file('echo/EchoWeb/deploy/environment/' + name, '')
        self.file('echo/.env', 'NOCODB_BASE_URL=https://nocodb.example.test\nECHO_WEB_NOCODB_API_TOKEN=keep-web-secret\nECHO_SERVICE_NOCODB_API_TOKEN=keep-service-secret\n')
        body = platform + '''
load_saved_inputs
SAVED_VALUES[ENVIRONMENT_NAME]=staging
phase_apps
'''
        first = self.shell(body)
        before = {path: path.read_bytes() for path in self.root.rglob('.env')}
        rows_before = (self.root / 'rows.json').read_bytes()
        second = self.shell(body)
        self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob('.env')})
        self.assertEqual(rows_before, (self.root / 'rows.json').read_bytes())
        for result in (first, second):
            self.assertNotIn('keep-app-secret', result.stdout + result.stderr)
            self.assertNotIn('aida-admin-db-secret', result.stdout + result.stderr)
        self.assertIn('aida-admin/DB_NAME=aida_admin_db', second.stdout)

    def test_full_officepulse_phase_reuses_system_service_token(self):
        platform = self.fake_platform()
        path = self.file('officepulse.env', 'NODE_ENV=production\nNOCODB_BASE_URL=https://nocodb.example.test\nNOCODB_API_TOKEN=pbx-secret\n')
        before = path.read_bytes()
        r = self.shell(platform + 'PHASE=officepulse; load_saved_inputs; phase_officepulse\n')
        self.assertEqual(path.read_bytes(), before)
        self.assertNotIn('pbx-secret', r.stdout + r.stderr)

    def test_actual_platform_rows_override_offline_hints_without_rotation(self):
        platform = self.fake_platform()
        self.shell(platform + '''
ensure_platformconfig
PARENT_DOMAIN=example.test; ENVIRONMENT_NAME=dev
SAVED_VALUES[ENVIRONMENT_NAME]=dev
sync_platform_identity
[ "$ENVIRONMENT_NAME" = staging ]
[ "$(row_get '*' ENVIRONMENT_NAME)" = staging ]
ENVIRONMENT_NAME=prod; GIVEN_INPUTS[ENVIRONMENT_NAME]=1
sync_platform_identity
[ "$(row_get '*' ENVIRONMENT_NAME)" = prod ]
''')

    def renamed_scope_fixture(self, settings):
        self.fake_platform()
        self.file('rows.json', json.dumps([dict(Id=i + 1, app=app, settingKey=key, settingValue=value)
                                          for i, (app, key, value) in enumerate(settings)]))
        return '''
TABLE_ID=test
rows_load() { ROWS_JSON=$(cat "$DIR/rows.json"); }
nc() { python3 "$DIR/fake_nc.py" "$DIR/rows.json" "$@"; }
rows_load
'''

    def test_renamed_scopes_move_existing_rows_in_place(self):
        settings = [('officepulse', 'DB_USER', 'aida_runtime'), ('officepulse', 'ARI_URL', 'http://pbx'),
                    ('aida-admin-runtime', 'DB_PASSWORD', 'reader-keep-secret'), ('aida', 'LIVEKIT_URL', 'wss://lk')]
        body = self.renamed_scope_fixture(settings)
        for _ in range(2):
            r = self.shell(body + 'rename_settings_scopes\n')
            self.assertNotIn('reader-keep-secret', r.stdout + r.stderr)
        rows = json.loads((self.root / 'rows.json').read_text())
        self.assertEqual([(row['Id'], row['app'], row['settingKey'], row['settingValue']) for row in rows], [
            (1, 'aida-pbx', 'DB_USER', 'aida_runtime'), (2, 'aida-pbx', 'ARI_URL', 'http://pbx'),
            (3, 'aida-pbx-reader', 'DB_PASSWORD', 'reader-keep-secret'), (4, 'aida', 'LIVEKIT_URL', 'wss://lk')])

    def test_renamed_scope_refuses_a_key_under_both_names(self):
        body = self.renamed_scope_fixture([('officepulse', 'ARI_URL', 'old'), ('aida-pbx', 'ARI_URL', 'new')])
        before = (self.root / 'rows.json').read_bytes()
        r = self.shell(body + 'rename_settings_scopes\n', ok=False)
        self.assertIn('officepulse/ARI_URL and aida-pbx/ARI_URL', r.stderr)
        self.assertEqual(before, (self.root / 'rows.json').read_bytes())

    def test_dry_run_reports_renamed_scopes_without_writes(self):
        body = self.renamed_scope_fixture([('officepulse', 'ARI_URL', 'old')])
        before = (self.root / 'rows.json').read_bytes()
        r = self.shell(body + 'DRY=1; nc() { die "dry run wrote"; }; rename_settings_scopes\n')
        self.assertIn('officepulse renamed aida-pbx', r.stdout)
        self.assertEqual(before, (self.root / 'rows.json').read_bytes())

    def test_literal_bootstrap_tokens_roundtrip_without_interpolation(self):
        for value in ('ordinary', 'literal$NAME#%40 with space', "quote'token", r'backslash\token',
                      'trailing\\', '"double\\quote"$', 'ends $with space\\', r'both\"$parts'):
            with self.subTest(value=value):
                self.env['EXPECTED_VALUE'] = value
                self.shell('env_write "$DIR/token.env" NOCODB_API_TOKEN "$EXPECTED_VALUE"\n'
                           '[ "$(env_get "$DIR/token.env" NOCODB_API_TOKEN)" = "$EXPECTED_VALUE" ]\n')

    def test_db_host_seed_cannot_redirect_existing_echo_jobs(self):
        # Test the exact phase segment: the accepted seed host is not a migration.
        text = INSTALL.read_text()
        start = text.index('  # DB_HOST seeds missing coordinates;')
        stop = text.index('  env_set "$echo_env" MYSQL_ADMIN_USER', start)
        segment = text[start:stop]
        path = self.file('echo/.env', 'ECHO_DB_HOST=current-job-host\n')
        self.shell('''
verify_host() {
  local echo_env="$DIR/echo/.env"
  DB_HOST=new-seed-host
  row_get() { printf '%s' current-app-host; }
''' + segment + '''
}
verify_host
[ "$(env_get "$DIR/echo/.env" ECHO_DB_HOST)" = current-job-host ]
rm "$DIR/echo/.env"
verify_host
[ "$(env_get "$DIR/echo/.env" ECHO_DB_HOST)" = current-app-host ]
''')
        self.assertIn('ECHO_DB_HOST=current-app-host', path.read_text())

    @unittest.skipUnless(shutil.which('docker'), 'Docker Compose validation runs in CI')
    def test_bootstrap_token_quoting_matches_docker_compose(self):
        compose = self.file('compose.yaml', 'services:\n  test:\n    image: busybox\n    environment:\n      TOKEN: "${NOCODB_API_TOKEN}"\n')
        for value in ('ordinary', 'literal$NAME#%40 with space', "quote'token", r'backslash\token', 'trailing\\', '"double\\quote"$', 'ends $with space\\', r'both\"$parts'):
            with self.subTest(value=value):
                self.env['EXPECTED_VALUE'] = value
                self.shell('env_write "$DIR/token.env" NOCODB_API_TOKEN "$EXPECTED_VALUE"\n'
                           '[ "$(env_get "$DIR/token.env" NOCODB_API_TOKEN)" = "$EXPECTED_VALUE" ]\n')
                result = subprocess.run(['docker', 'compose', '--env-file', str(self.root / 'token.env'),
                                         '-f', str(compose), 'config', '--environment'],
                                        text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Rendered Compose YAML/JSON re-escapes dollars for reuse. Inspect
                # the parsed interpolation environment, not that serialized model.
                parsed = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
                self.assertEqual(parsed['NOCODB_API_TOKEN'], value)


if __name__ == '__main__':
    unittest.main()
