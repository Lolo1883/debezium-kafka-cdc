# Debezium Kafka CDC — PostgreSQL → MSSQL

Change Data Capture pipeline that streams database changes from **PostgreSQL** to **Microsoft SQL Server** in near real-time using Kafka and Debezium.

Built as a reference for replicating the **KEP energy management system** from Scaleway (PostgreSQL source) to Hetzner (MSSQL target) — but the pattern applies to any PostgreSQL → MSSQL replication use case.

This repo contains two things:

| | |
|---|---|
| **`/` (root)** | Local POC — full stack in Docker including both databases. Run it on your laptop to understand and test the pipeline end-to-end. |
| **`/blueprint`** | Production template — Kafka stack only (no databases). Deploy on a VM with access to both clouds, point at real DBs. |

---

## Architecture

```
┌──────────────────────┐     ┌──────────────────────────────────┐     ┌─────────────────────┐
│  PostgreSQL (source) │     │  Kafka + Kafka Connect            │     │  MSSQL (sink)       │
│                      │─────▶  Debezium source connector        │────▶│                     │
│  wal_level=logical   │ WAL │  reads changes via pgoutput       │     │  Tables auto-created│
│  kep_publication     │     │  publishes JSON to Kafka topics   │     │  JDBC upsert        │
└──────────────────────┘     │                                   │     └─────────────────────┘
                             │  JDBC sink connector              │
                             │  consumes topics → upserts rows   │
                             └──────────────────────────────────┘
                                        + Kafka UI
                                    http://localhost:8080
```

**CDC event flow:**
1. A row changes in PostgreSQL → written to the WAL
2. Debezium reads from the WAL via a replication slot (`pgoutput` plugin)
3. Published as a JSON message to a Kafka topic (`kep.public.<table>`)
4. Two SMTs transform the message before it hits MSSQL:
   - `ExtractNewRecordState` — unwraps Debezium envelope, keeps only the row values
   - `RegexRouter` — strips the topic prefix so the table name in MSSQL is clean
5. JDBC sink upserts the row into MSSQL

---

## Repository structure

```
├── docker-compose.yml          # POC — all 6 services including both databases
├── setup.sh                    # Registers connectors after docker compose up
├── simulate.sh                 # Inserts live events to watch the pipeline
├── verify.sh                   # Compares row counts source vs sink
│
├── connect/
│   └── Dockerfile              # Kafka Connect + Debezium PG + JDBC + MSSQL driver
│
├── connectors/
│   ├── source-postgres.json    # Debezium source connector config (POC)
│   └── sink-mssql.json         # JDBC sink connector config (POC)
│
├── postgres/
│   └── init.sql                # Schema, 24h seed data, replication publication
│
├── mssql/
│   ├── Dockerfile              # Python + pymssql (ARM-compatible DB init)
│   ├── init-db.py              # Creates kep_target database on first start
│   └── init-db.sh              # Entrypoint for the mssql-init container
│
└── blueprint/                  # Production setup — see blueprint/README.md
    ├── docker-compose.yml      # Kafka + Connect + Kafka UI only (no databases)
    ├── .env.example            # All config/secrets as env vars
    ├── register-connectors.sh  # Reads .env, substitutes vars, POSTs connectors
    ├── postgres-setup.sql      # One-time setup on Scaleway managed PostgreSQL
    ├── mssql-setup.sql         # One-time setup on Hetzner MSSQL
    ├── kafka-connect.env       # Kafka Connect environment reference
    └── connectors/
        ├── source-postgres.json  # Production source template ($VAR from .env)
        └── sink-mssql.json       # Production sink template ($VAR from .env)
```

---

## Part 1 — Local POC

Runs the full pipeline locally including both databases. Everything is self-contained.

### Services

| Container | Image | Port | Role |
|---|---|---|---|
| `zookeeper` | confluentinc/cp-zookeeper:7.6.0 | internal | Kafka coordination |
| `kafka` | confluentinc/cp-kafka:7.6.0 | 29092 | Message broker |
| `kep-postgres` | postgres:15 | 5432 | Source database (KEP / Scaleway side) |
| `kep-mssql` | mcr.microsoft.com/azure-sql-edge | 1433 | Sink database (Hetzner side) |
| `kafka-connect` | custom (see connect/Dockerfile) | 8083 | Runs source + sink connectors |
| `kafka-ui` | provectuslabs/kafka-ui | 8080 | Visual Kafka topic browser |
| `mssql-init` | custom python+pymssql | — | Creates `kep_target` DB, exits |

> **Apple Silicon (M1/M2/M3):** Uses `azure-sql-edge` which is ARM-native. Production uses standard MSSQL — same JDBC connector, same configs.

### Prerequisites

- Docker Desktop — set memory to at least **6 GB** (Settings → Resources → Memory)
- ~3 GB free disk

### Run it

**Step 1 — Start all services**

```bash
docker compose up -d --build
```

First run is slow (~5–10 min) — the Connect image downloads Debezium, JDBC connector, and MSSQL JDBC driver. Subsequent starts are fast (cached).

Wait until all containers are healthy:

```bash
docker compose ps
```

All should show `healthy`. `mssql-init` should show `exited (0)` — that means it created the `kep_target` database and exited cleanly.

**Step 2 — Register the connectors**

```bash
./setup.sh
```

Waits for Kafka Connect, then registers both connectors. Debezium immediately starts snapshotting all existing PostgreSQL rows into Kafka. The JDBC sink starts consuming and writing to MSSQL.

Expected final output:

```
kep-postgres-source    RUNNING   tasks=['RUNNING']
kep-mssql-sink         RUNNING   tasks=['RUNNING']
```

**Step 3 — Verify the snapshot landed**

```bash
./verify.sh
```

```
Table                     PostgreSQL      MSSQL
────────────────────────────────────────────────────────────────
devices                            5          5  ✓
energy_readings                  485        485  ✓
```

**Step 4 — Simulate live changes**

```bash
./simulate.sh
```

Inserts 10 new readings (2s apart), then triggers an UPDATE and a soft-delete. Watch Kafka UI → Topics while it runs, then re-run `./verify.sh` to confirm MSSQL caught up.

### Connect to the databases directly

**PostgreSQL (source)**
```
Host:     localhost
Port:     5432
Database: kep_db
User:     kep_user
Password: kep_password
```

```bash
docker exec -it kep-postgres psql -U kep_user -d kep_db
```

**MSSQL (sink)**
```
Host:     localhost
Port:     1433
Database: kep_target
User:     sa
Password: KEP_Strong!Pass123
Encrypt:  false / trust cert: true
```

Tables are in the **`dbo`** schema — `kep_target → Schemas → dbo → Tables`.

### Kafka UI

Open **http://localhost:8080**

- **Topics** → `kep.public.devices` and `kep.public.energy_readings`
- Click a topic → **Messages** to browse individual CDC events (each has `before`, `after`, `op` fields)
- **Consumer Groups** → `kep-connect-group` to see lag

### Tear down

```bash
# Stop, keep volumes (data survives restart)
docker compose down

# Full reset
docker compose down -v
```

---

## Part 2 — Production Blueprint

See **[blueprint/README.md](./blueprint/README.md)** for the complete production guide.

### What it covers

- One-time PostgreSQL setup on Scaleway managed PG (replication user, publication)
- One-time MSSQL setup on Hetzner Windows Server (target DB, sink user, firewall)
- `docker-compose.yml` for the Kafka stack VM (Kafka + Connect + Kafka UI — no databases)
- `.env.example` with all credentials and config as variables
- `register-connectors.sh` that reads `.env` and registers both connectors in one command
- Networking checklist (which ports to open, from where to where)
- Security hardening checklist

### Quick start (on the production VM)

```bash
cd blueprint
cp .env.example .env
vi .env                       # fill in Scaleway PG host, Hetzner MSSQL host, passwords, table names
docker compose up -d --build
./register-connectors.sh
```

---

## How the connectors work

### Source — Debezium PostgreSQL

```json
"plugin.name": "pgoutput"               // native PostgreSQL logical replication
"publication.autocreate.mode": "disabled" // publication created manually in init.sql
"snapshot.mode": "initial"              // snapshot existing rows first, then stream
"decimal.handling.mode": "double"       // avoids schema conflicts with DECIMAL types
```

Produces messages to topics named `<prefix>.public.<table>`.

Each message value is a Debezium envelope:
```json
{
  "before": { ...old row... },
  "after":  { ...new row... },
  "op":     "c",               // c=insert  u=update  d=delete  r=snapshot read
  "ts_ms":  1710000000000
}
```

### Sink — Confluent JDBC

```json
"insert.mode": "upsert"                 // idempotent, safe to replay
"pk.mode": "record_key"                 // uses Kafka message key (= source PK) as MSSQL PK
"auto.create": "true"                   // creates MSSQL table on first message
"delete.handling.mode": "rewrite"       // deletes become __deleted=true rows, not actual DELETEs
```

Two transforms run before writing:

1. **`ExtractNewRecordState`** — strips the Debezium envelope, leaves only the `after` row values (+ `__op`, `__ts_ms`, `__deleted` columns)
2. **`RegexRouter`** — renames `kep.public.energy_readings` → `energy_readings` (used as MSSQL table name)

---

## Adding a new table

**1. Add it to the PostgreSQL publication:**
```sql
ALTER PUBLICATION kep_publication ADD TABLE public.new_table;
```

**2. Update the source connector:**
```bash
curl -X PUT http://localhost:8083/connectors/kep-postgres-source/config \
  -H "Content-Type: application/json" \
  -d '{ ...existing config..., "table.include.list": "public.devices,public.energy_readings,public.new_table" }'
```

**3. Update the sink connector topics list the same way.**

MSSQL table is created automatically on the first message.
