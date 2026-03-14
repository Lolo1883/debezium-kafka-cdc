#!/usr/bin/env bash
# =============================================================================
# Register source + sink connectors against the running Kafka Connect instance.
# Run AFTER: docker compose up -d --build
# =============================================================================

set -euo pipefail

CONNECT_URL="http://localhost:8083"
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${BLUE}[setup]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}    $*"; }
warn() { echo -e "${YELLOW}[wait]${NC}  $*"; }

# Load .env so we can substitute placeholders at registration time
if [ ! -f .env ]; then
    echo "ERROR: .env file not found. Copy .env.example to .env and fill in values."
    exit 1
fi
set -a; source .env; set +a

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║     KEP CDC — Register Production Connectors     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Wait for Kafka Connect ─────────────────────────────────────────────────────
log "Waiting for Kafka Connect REST API..."
until curl -sf "$CONNECT_URL/connectors" >/dev/null 2>&1; do
    warn "not ready yet, retrying in 5s..."
    sleep 5
done
ok "Kafka Connect is up"
echo ""

# ── Helper: register or replace a connector ──────────────────────────────────
register() {
    local name=$1
    local config_file=$2

    EXISTING=$(curl -s "$CONNECT_URL/connectors" | grep -o "\"$name\"" || true)
    if [ -n "$EXISTING" ]; then
        warn "Connector '$name' already exists — deleting and re-creating..."
        curl -sf -X DELETE "$CONNECT_URL/connectors/$name" >/dev/null
        sleep 2
    fi

    # Substitute env vars inside the JSON template before posting
    envsubst < "$config_file" | curl -sf -X POST "$CONNECT_URL/connectors" \
        -H "Content-Type: application/json" \
        -d @- | python3 -m json.tool 2>/dev/null || true
    echo ""
}

# ── Register connectors ───────────────────────────────────────────────────────
log "Registering PostgreSQL → Kafka source connector..."
register "kep-postgres-source" connectors/source-postgres.json
ok "Source connector registered"
echo ""

log "Registering Kafka → MSSQL sink connector..."
register "kep-mssql-sink" connectors/sink-mssql.json
ok "Sink connector registered"
echo ""

# ── Print status ──────────────────────────────────────────────────────────────
sleep 5
echo "── Connector status ─────────────────────────────────────"
curl -s "$CONNECT_URL/connectors?expand=status" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for name, v in data.items():
    st    = v.get('status', {})
    conn  = st.get('connector', {})
    tasks = st.get('tasks', [])
    print(f'  {name:40s}  {conn.get(\"state\",\"?\"):10s}  tasks={[t.get(\"state\") for t in tasks]}')
" 2>/dev/null
echo ""
echo "─────────────────────────────────────────────────────────"
echo ""
echo "  Kafka UI      →  http://${KAFKA_HOST}:8080"
echo "  Kafka Connect →  http://${KAFKA_HOST}:8083"
echo ""
