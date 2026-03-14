-- =============================================================================
-- KEP CDC Blueprint — MSSQL setup (run once on Hetzner Windows Server)
-- =============================================================================
-- Connect to your MSSQL instance as sa or a sysadmin account and run this.
-- The JDBC sink connector will auto-create tables, but the DATABASE and USER
-- must exist before registering the connector.
-- =============================================================================


-- ── 1. Create the target database ────────────────────────────────────────────

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = '<TARGET_DATABASE_NAME>')
    CREATE DATABASE <TARGET_DATABASE_NAME>;
GO

USE <TARGET_DATABASE_NAME>;
GO


-- ── 2. Create a dedicated sink user (least privilege) ────────────────────────
-- Avoid using 'sa' in production.

CREATE LOGIN debezium_sink WITH PASSWORD = '<SINK_USER_PASSWORD>';
CREATE USER  debezium_sink FOR LOGIN debezium_sink;

-- The sink connector needs to CREATE tables (auto.create=true) and INSERT/UPDATE rows
EXEC sp_addrolemember 'db_ddladmin',    'debezium_sink';
EXEC sp_addrolemember 'db_datawriter',  'debezium_sink';
EXEC sp_addrolemember 'db_datareader',  'debezium_sink';
GO


-- ── 3. (Optional) Pre-create target tables ───────────────────────────────────
-- If you leave auto.create=true in the sink connector, tables are created
-- automatically from the Kafka message schema on first message.
-- Pre-creating them gives you control over data types and indexes.
--
-- Replace the column definitions below with your actual KEP table structures.

-- Example — replace with your real table:
/*
CREATE TABLE <TABLE_1> (
    id          BIGINT          NOT NULL,
    <column_1>  NVARCHAR(50)    NOT NULL,
    <column_2>  NVARCHAR(100),
    <column_3>  DATETIME2,
    <column_4>  DECIMAL(10, 3),
    created_at  DATETIME2,
    -- Debezium metadata columns added by ExtractNewRecordState SMT:
    __op        NVARCHAR(1),    -- c=create, u=update, d=delete, r=snapshot
    __ts_ms     BIGINT,         -- source event timestamp in ms
    __deleted   NVARCHAR(5),    -- 'true' when record was deleted in source
    CONSTRAINT PK_<TABLE_1> PRIMARY KEY (id)
);

CREATE TABLE <TABLE_2> (
    id                BIGINT          NOT NULL,
    <column_1>        NVARCHAR(50),
    <column_2>        DATETIME2,
    <column_3>        DECIMAL(12, 6),
    CONSTRAINT PK_<TABLE_2> PRIMARY KEY (id)
);
*/

-- ── 4. Network / firewall ─────────────────────────────────────────────────────
-- On the Hetzner Windows Server, ensure:
-- • Windows Firewall allows inbound TCP on port 1433 from the Kafka Connect host IP
-- • SQL Server Configuration Manager → TCP/IP is enabled and listening on port 1433
-- • SQL Server Browser service is running (if using named instances)
