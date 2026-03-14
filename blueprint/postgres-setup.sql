-- =============================================================================
-- KEP CDC Blueprint — PostgreSQL setup (run once on Scaleway managed PostgreSQL)
-- =============================================================================
-- Run this as the admin/superuser on your Scaleway managed PostgreSQL instance.
-- Scaleway managed PG already has wal_level=logical enabled by default.
-- =============================================================================

-- ── 1. Create a dedicated replication user ───────────────────────────────────
-- Use a dedicated user rather than the admin account for least-privilege.

CREATE USER debezium_user WITH PASSWORD '<DEBEZIUM_USER_PASSWORD>';

-- Required for Debezium to open a replication slot
ALTER USER debezium_user REPLICATION;

-- Required for Debezium to read the schema
GRANT USAGE ON SCHEMA public TO debezium_user;

-- Required for the initial snapshot (Debezium reads all existing rows first)
-- Replace 'your_schema' if you use a custom schema
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;

-- Ensure future tables are also readable
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium_user;


-- ── 2. Create the logical replication publication ────────────────────────────
-- List every table you want to capture CDC events for.
-- Replace the table names below with your actual KEP table names.

CREATE PUBLICATION kep_cdc_publication FOR TABLE
    <TABLE_1>,
    <TABLE_2>,
    <TABLE_3>;
    -- add more tables as needed

-- To add a table to an existing publication later:
-- ALTER PUBLICATION kep_cdc_publication ADD TABLE <new_table>;

-- To verify:
-- SELECT * FROM pg_publication;
-- SELECT * FROM pg_publication_tables WHERE pubname = 'kep_cdc_publication';


-- ── 3. Verify logical replication is enabled ─────────────────────────────────
-- Should return 'logical'
SHOW wal_level;

-- Scaleway managed PG notes:
-- - wal_level is already 'logical' on Scaleway managed instances
-- - max_replication_slots defaults to 10 (sufficient)
-- - The debezium_user needs network access from the Kafka Connect host
--   → whitelist the Kafka Connect server IP in Scaleway's allowed IPs list
