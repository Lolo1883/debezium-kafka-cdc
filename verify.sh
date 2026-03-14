#!/usr/bin/env bash
# =============================================================================
# Compare row counts and sample data between PostgreSQL (source) and MSSQL (sink)
# =============================================================================

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SEP="────────────────────────────────────────────────────────────────"

# Detect sqlcmd path inside the MSSQL container
run_pg()   { docker exec kep-postgres psql -U kep_user -d kep_db -t -A -c "$1" 2>/dev/null; }
# Reuse the kep-pymssql image built by docker compose (has pymssql pre-installed)
run_mssql(){
    docker run --rm --network debezium_default kep-pymssql \
        python -c "
import pymssql
conn = pymssql.connect('mssql','sa','KEP_Strong!Pass123','kep_target')
cur = conn.cursor()
cur.execute('$1')
for row in cur: print(row[0])
conn.close()
" 2>/dev/null || echo "(error)"
}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      KEP CDC Verification – Source vs Sink       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""


# ── Row counts ────────────────────────────────────────────────────────────────
echo -e "${BLUE}Row counts:${NC}"
printf "  %-25s %10s %10s\n" "Table" "PostgreSQL" "MSSQL"
echo "  $SEP"

for table in devices energy_readings; do
    pg_count=$(run_pg    "SELECT COUNT(*) FROM $table")
    ms_count=$(run_mssql "SELECT COUNT(*) FROM $table" | grep -E '^[0-9]+$' | tail -1)
    ms_count=${ms_count:-"(no table)"}

    if [ "$pg_count" = "$ms_count" ]; then
        status="${GREEN}✓${NC}"
    else
        status="${YELLOW}≠${NC}"
    fi
    printf "  %-25s %10s %10s  %b\n" "$table" "$pg_count" "$ms_count" "$status"
done
echo ""

# ── Sample rows from MSSQL ────────────────────────────────────────────────────
echo -e "${BLUE}Latest 5 energy readings in MSSQL (sink):${NC}"
docker run --rm --network debezium_default kep-pymssql python -c "
import pymssql
conn = pymssql.connect('mssql','sa','KEP_Strong!Pass123','kep_target')
cur = conn.cursor()
cur.execute('SELECT TOP 5 id, device_id, CAST(reading_timestamp AS VARCHAR), power_kw, energy_kwh FROM energy_readings ORDER BY id DESC')
for row in cur: print(' | '.join(str(c) for c in row))
conn.close()
" 2>/dev/null || echo "  (table not yet created)"
echo ""

# ── Kafka topic lag (requires kfk container to be up) ────────────────────────
echo -e "${BLUE}Kafka consumer group lag:${NC}"
docker exec kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --group kep-connect-group \
    --describe 2>/dev/null | grep -E "TOPIC|kep\." || echo "  (no data yet)"
echo ""

# ── Connector status ──────────────────────────────────────────────────────────
echo -e "${BLUE}Connector status:${NC}"
curl -s "http://localhost:8083/connectors?expand=status" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for name, v in data.items():
    st  = v.get('status', {})
    conn = st.get('connector', {})
    tasks = st.get('tasks', [])
    task_states = [t.get('state') for t in tasks]
    print(f\"  {name:40s}  {conn.get('state','?')}  tasks={task_states}\")
" 2>/dev/null
echo ""
