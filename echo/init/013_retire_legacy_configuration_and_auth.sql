USE echo_db;

-- Disposable Dev cutover: PlatformConfig is the only settings source and
-- Identity owns users, tenants, memberships, sessions and number assignments.
-- Deploy the matching EchoWeb/EchoService readers before applying this file.
-- These obsolete tables and their data are intentionally discarded; there is
-- no rollback copy. Child-first order preserves foreign-key enforcement.
DROP TABLE IF EXISTS echo_tbl_Settings;
DROP TABLE IF EXISTS echo_tbl_PlatformOrgMap;
DROP TABLE IF EXISTS echo_tbl_PlatformUserMap;
DROP TABLE IF EXISTS auth_tbl_Identity;
DROP TABLE IF EXISTS auth_tbl_Membership;
DROP TABLE IF EXISTS auth_tbl_Session;
DROP TABLE IF EXISTS auth_tbl_SsoNonce;
DROP TABLE IF EXISTS auth_tbl_User;
DROP TABLE IF EXISTS auth_tbl_Org;

-- Active sms_* data and echo_tbl_SchemaMigration are not obsolete and remain.
