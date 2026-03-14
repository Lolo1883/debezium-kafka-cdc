# KEP CDC Blueprint — Production Setup

Real-world architecture for replicating KEP energy data from **Scaleway PostgreSQL** to **Hetzner MSSQL** using Kafka + Debezium.

> This is the production blueprint. For the local POC see the root `docker-compose.yml`.

---

## Architecture

```
┌─────────────────────────┐        ┌──────────────────────────┐        ┌──────────────────────────┐
│  Scaleway               │        │  Kafka Cluster           │        │  Hetzner                 │
│  Managed PostgreSQL     │──CDC──▶│  (your preferred host)   │──────▶│  Windows Server          │
│  wal_level = logical    │        │  + Kafka Connect         │        │  SQL Server              │
│  kep_cdc_publication    │        │  Debezium source         │        │  <TARGET_DATABASE_NAME>  │
│                         │        │  JDBC sink               │        │                          │
└─────────────────────────┘        └──────────────────────────┘        └──────────────────────────┘
         port 5432                      port 8083 (REST)                       port 1433
```

**Kafka cluster placement:** Deploy Kafka + Kafka Connect on a Scaleway VM in the same region as your PostgreSQL — this minimises latency on the high-throughput source side. The JDBC sink pushes data to Hetzner over the internet (low volume, one record at a time in near real-time).

---

## Placeholders reference

| Placeholder | What to fill in |
|---|---|
| `<SCALEWAY_PG_HOST>` | Scaleway managed PG hostname, e.g. `xxxx.pg.sdb.fr-par.scaleway.com` |
| `<POSTGRES_DATABASE_NAME>` | Your KEP database name |
| `<DEBEZIUM_USER_PASSWORD>` | Password for the `debezium_user` replication account |
| `<HETZNER_MSSQL_HOST>` | Public IP or hostname of the Hetzner Windows Server |
| `<TARGET_DATABASE_NAME>` | MSSQL target database name, e.g. `kep_target` |
| `<SINK_USER_PASSWORD>` | Password for the `debezium_sink` SQL Server account |
| `<TOPIC_PREFIX>` | Short identifier for your Kafka topics, e.g. `kep` |
| `<TABLE_1>`, `<TABLE_2>`… | Your actual PostgreSQL table names |
| `<KAFKA_BROKER_*_HOST>` | Kafka broker hostnames/IPs |
| `<KAFKA_CONNECT_HOST>` | The VM running Kafka Connect |

---

## Step-by-step

### Step 1 — PostgreSQL (Scaleway) — run once

Connect to your Scaleway managed PostgreSQL as admin and run:

```bash
psql -h <SCALEWAY_PG_HOST> -U <ADMIN_USER> -d <POSTGRES_DATABASE_NAME> -f postgres-setup.sql
```

What it does:
- Creates `debezium_user` with REPLICATION privilege
- Grants SELECT on all tables to that user
- Creates `kep_cdc_publication` for your target tables

**Scaleway note:** `wal_level=logical` is enabled by default on managed instances — no server config change needed.

---

### Step 2 — MSSQL (Hetzner Windows Server) — run once

Connect via SSMS or sqlcmd and run `mssql-setup.sql`:

```bash
sqlcmd -S <HETZNER_MSSQL_HOST>,1433 -U sa -P <SA_PASSWORD> -i mssql-setup.sql
```

What it does:
- Creates the target database
- Creates `debezium_sink` login with db_ddladmin + db_datawriter privileges
- (Optional) Pre-creates target tables with correct types

**Windows Firewall:** Open port 1433 inbound from the Kafka Connect VM IP:
```
# In Windows Firewall (PowerShell as admin):
New-NetFirewallRule -DisplayName "MSSQL Kafka Connect" -Direction Inbound -Protocol TCP -LocalPort 1433 -RemoteAddress <KAFKA_CONNECT_VM_IP> -Action Allow
```

---

### Step 3 — Deploy Kafka Connect

Use the same Docker image from the POC (`connect/Dockerfile`) or any Kafka Connect deployment. Copy `kafka-connect.env` and fill in the broker addresses.

```bash
docker run -d \
  --env-file kafka-connect.env \
  -p 8083:8083 \
  your-kafka-connect-image
```

Or deploy via Kubernetes, Ansible, etc.

---

### Step 4 — Register connectors

Fill in the placeholders in `connectors/source-postgres.json` and `connectors/sink-mssql.json`, then POST them to the Connect REST API:

```bash
# Register source (Debezium reads from PostgreSQL WAL)
curl -X POST http://<KAFKA_CONNECT_HOST>:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connectors/source-postgres.json

# Register sink (JDBC writes to MSSQL)
curl -X POST http://<KAFKA_CONNECT_HOST>:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connectors/sink-mssql.json
```

Check status:
```bash
curl -s http://<KAFKA_CONNECT_HOST>:8083/connectors?expand=status
```

Both connectors should show `RUNNING`.

---

### Step 5 — Add a new table later

1. Add it to the PostgreSQL publication:
```sql
ALTER PUBLICATION kep_cdc_publication ADD TABLE public.<new_table>;
```

2. Update the source connector:
```bash
curl -X PUT http://<KAFKA_CONNECT_HOST>:8083/connectors/kep-postgres-source/config \
  -H "Content-Type: application/json" \
  -d '{ ...same config with new table added to table.include.list... }'
```

3. Update the sink connector topics list the same way.

---

## Networking checklist

| Connection | From | To | Port | Action needed |
|---|---|---|---|---|
| Debezium → PostgreSQL | Kafka Connect VM | Scaleway PG | 5432 | Whitelist Connect VM IP in Scaleway allowed IPs |
| JDBC sink → MSSQL | Kafka Connect VM | Hetzner Windows Server | 1433 | Open Windows Firewall inbound rule |
| Kafka Connect → Kafka | Kafka Connect VM | Kafka brokers | 9092 | Must be in same network or VPN |
| Operators → Connect REST | Your machine | Kafka Connect VM | 8083 | Open as needed |

---

## What Debezium creates automatically (do NOT create manually)

- **Replication slot** `kep_debezium_slot` — created in PostgreSQL by Debezium on first start
- **Kafka topics** `<TOPIC_PREFIX>.public.<TABLE_NAME>` — created by Kafka Connect automatically
- **MSSQL tables** — created by the JDBC sink connector on first message (`auto.create=true`)

---

## Security hardening (production checklist)

- [ ] Use SSL for PostgreSQL connection (`"database.sslmode": "require"` is already in the connector)
- [ ] Use SSL for MSSQL connection (`encrypt=true` is already in the connector — remove `trustServerCertificate=false` only after installing a valid cert on the server)
- [ ] Store passwords in a secrets manager (Vault, AWS Secrets Manager, etc.) — not in connector JSON files
- [ ] Restrict `debezium_user` to only the tables in the publication (already done via GRANT SELECT)
- [ ] Restrict `debezium_sink` to only the target database (already done)
- [ ] Monitor replication slot lag — a stuck connector will cause WAL to accumulate on PostgreSQL and fill the disk
