"""Installer DB_* contracts, without touching NocoDB, Docker, MySQL or a live account."""
import json
import os
from pathlib import Path
import subprocess
import unittest
from urllib.parse import quote

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
HARNESS = r'''
INSTALL_SOURCE_ONLY=1 source "$1"
PARENT_DOMAIN=example.test
ROWS_JSON=$(cat)
note() { :; }
row_ensure() {
  local app=$1 key=$2 value=$3 secret=$4 desc=$5
  ROWS_JSON=$(jq --arg a "$app" --arg k "$key" --arg v "$value" --argjson s "$secret" '
    if any(.[]; .app==$a and .settingKey==$k) then
      map(if .app==$a and .settingKey==$k and ((.settingValue // "") == "") then .settingValue=$v | .bSecret=$s else . end)
    else . + [{app:$a,settingKey:$k,settingValue:$v,bSecret:$s}] end' <<<"$ROWS_JSON")
}
seed_aida_database_settings platform-mysql-local
first=$ROWS_JSON
secret() { die 'An idempotent rerun must not generate a new password'; }
seed_aida_database_settings ignored-second-host
[ "$ROWS_JSON" = "$first" ] || die 'Rerun changed existing configuration'
aida_database_accounts_ready || die 'Seeded accounts should be ready'
printf '%s\n' "$ROWS_JSON"
# Verify the same literal passwords go to provisioning, including trailing newlines.
printf '%s\0' "${AIDA_ADMIN_DB_ARGS[@]}" "${AIDA_RUNTIME_DB_ARGS[@]}" "${AIDA_READER_DB_ARGS[@]}" >&3
'''


def row(app, key, value):
    return {"app": app, "settingKey": key, "settingValue": value}


class DatabaseSettingsTests(unittest.TestCase):
    def run_seed(self, rows=(), success=True):
        # FD 3 shares stdout after a marker, keeping arbitrary newlines in args lossless.
        script = HARNESS.replace('>&3', '').replace("printf '%s\\0'", "printf '\\nARGS\\n'; printf '%s\\0'")
        result = subprocess.run(["bash", "-c", script, "bash", str(INSTALL)],
                                input=json.dumps(list(rows)), text=True, capture_output=True,
                                env={**os.environ, "INSTALL_SOURCE_ONLY": "1"})
        if not success:
            self.assertNotEqual(result.returncode, 0)
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        settings, args = result.stdout.split("\nARGS\n", 1)
        parsed = json.loads(settings)
        return {(r["app"], r["settingKey"]): r for r in parsed}, args.split("\0")

    def test_fresh_settings_are_scoped_secret_and_idempotent(self):
        rows, args = self.run_seed()
        self.assertEqual(len(rows), 15)
        for app, name, user, host in [
            ("aida-admin", "aida_admin_db", "aida_admin_app", "platform-mysql-local"),
            ("aida-pbx", "aidacalls_db", "aida_runtime", "lsdb.example.test"),
            ("aida-pbx-reader", "aidacalls_db", "aidaadmin_ro", "platform-mysql-local"),
        ]:
            for key, value in {"DB_NAME": name, "DB_USER": user, "DB_HOST": host, "DB_PORT": "3306"}.items():
                self.assertEqual(rows[app, key]["settingValue"], value)
            password = rows[app, "DB_PASSWORD"]
            self.assertTrue(password["bSecret"])
            prefix = "READER_DB_PASSWORD=" if app == "aida-pbx-reader" else "DB_PASSWORD="
            self.assertIn(prefix + password["settingValue"], args)
        self.assertEqual(len({rows[app, "DB_PASSWORD"]["settingValue"]
                              for app in ("aida-admin", "aida-pbx", "aida-pbx-reader")}), 3)

    def test_migrates_urls_and_old_runtime_keys_without_rotating_or_trimming(self):
        admin_password, reader_password, writer_password = "p@ss%:/é'\\\n", " reader'\\$()%40\n", "writer%40\n"
        rows, args = self.run_seed([
            row("aida-admin", "AIDA_ADMIN_DATABASE_URL", f"mysql://aida_admin_app:{quote(admin_password, safe='')}@admin-host:3307/aida_admin_db"),
            row("aida-admin", "OFFICEPULSE_RUNTIME_DATABASE_URL", f"mysql://aidaadmin%5Fro:{quote(reader_password, safe='')}@reader-host:3308/aidacalls_db"),
            row("aida-pbx", "RUNTIME_MYSQL_HOST", "127.0.0.1"),
            row("aida-pbx", "RUNTIME_MYSQL_PORT", "13306"),
            row("aida-pbx", "RUNTIME_MYSQL_USER", "aida_runtime"),
            row("aida-pbx", "RUNTIME_MYSQL_DATABASE", "aidacalls_db"),
            row("aida-pbx", "RUNTIME_MYSQL_PASSWORD", writer_password),
        ])
        for app, expected in [("aida-admin", admin_password), ("aida-pbx-reader", reader_password), ("aida-pbx", writer_password)]:
            self.assertEqual(rows[app, "DB_PASSWORD"]["settingValue"], expected)
            prefix = "READER_DB_PASSWORD=" if app == "aida-pbx-reader" else "DB_PASSWORD="
            self.assertIn(prefix + expected, args)
        self.assertEqual(rows["aida-pbx", "DB_HOST"]["settingValue"], "127.0.0.1")
        self.assertEqual(rows["aida-pbx", "DB_PORT"]["settingValue"], "13306")
        self.assertEqual(rows["aida-pbx-reader", "DB_USER"]["settingValue"], "aidaadmin_ro")
        self.assertEqual(rows["aida-admin", "DB_PORT"]["settingValue"], "3307")

    def test_canonical_rows_override_legacy_fields(self):
        rows, _ = self.run_seed([
            row("aida-admin", "AIDA_ADMIN_DATABASE_URL", "mysql://aida_admin_app:old@old-host/aida_admin_db"),
            row("aida-admin", "DB_HOST", "new-host"), row("aida-admin", "DB_PASSWORD", "new%40literal"),
        ])
        self.assertEqual(rows["aida-admin", "DB_HOST"]["settingValue"], "new-host")
        self.assertEqual(rows["aida-admin", "DB_PASSWORD"]["settingValue"], "new%40literal")

    def test_complete_canonical_settings_ignore_unusable_retired_rows(self):
        initial = [row("aida-admin", key, value) for key, value in {
            "DB_HOST": "db", "DB_NAME": "aida_admin_db", "DB_USER": "aida_admin_app", "DB_PASSWORD": "literal"
        }.items()]
        initial.append(row("aida-admin", "AIDA_ADMIN_DATABASE_URL", "invalid-secret-must-not-be-read"))
        rows, _ = self.run_seed(initial)
        self.assertEqual(rows["aida-admin", "DB_PORT"]["settingValue"], "3306")

    def test_rejects_malformed_legacy_credentials_without_exposing_values(self):
        for value in ["sensitive-not-a-url", "mysql://u:secret%GG@h/aida_admin_db",
                      "mysql://u:secret%00@h/aida_admin_db", "mysql://u:@h/aida_admin_db"]:
            with self.subTest(value=value):
                result = self.run_seed([row("aida-admin", "AIDA_ADMIN_DATABASE_URL", value)], success=False)
                self.assertNotIn(value, result.stderr)
                self.assertNotIn("secret%", result.stderr)

    def test_runtime_reader_cannot_use_another_schema_or_writer(self):
        for key, value in [("DB_NAME", "different_db"), ("DB_USER", "aida_runtime")]:
            with self.subTest(key=key):
                self.run_seed([row("aida-pbx-reader", key, value)], success=False)

    def test_admin_store_account_cannot_be_the_runtime_reader(self):
        result = self.run_seed([row("aida-admin", "DB_USER", "aidaadmin_ro")], success=False)
        self.assertIn("distinct DB_USER", result.stderr)

    def test_dry_run_uses_no_api_writes_and_does_not_print_passwords(self):
        script = r'''
INSTALL_SOURCE_ONLY=1 source "$1"
PARENT_DOMAIN=example.test; ROWS_JSON='[]'; TABLE_ID=dry; DRY=1
secret() { printf 'sensitive-generated-password'; }
nc() { die 'Dry run attempted an API write'; }
seed_aida_database_settings platform-mysql-local
[ "$ROWS_JSON" = '[]' ]
'''
        result = subprocess.run(["bash", "-c", script, "bash", str(INSTALL)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("sensitive-generated-password", result.stdout + result.stderr)
        self.assertIn("DB_PASSWORD", result.stdout)


if __name__ == "__main__":
    unittest.main()
