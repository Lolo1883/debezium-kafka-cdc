#!/usr/bin/env bash
# =============================================================================
# KEP CDC Pipeline – setup script
# Run AFTER: docker compose up -d --build
# =============================================================================

set -euo pipefail

CONNECT_URL="http://localhost:8083"
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${BLUE}[setup]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}    $*"; }
warn() { echo -e "${YELLOW}[wait]${NC}  $*"; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   KEP CDC Pipeline – PostgreSQL → Kafka → MSSQL ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Wait for Kafka Connect REST API ───────────────────────────────────────
log "Waiting for Kafka Connect…"
until curl -sf "$CONNECT_URL/connectors" >/dev/null 2>&1; do
    warn "not ready yet, retrying in 5 s…"
    sleep 5
done
ok "Kafka Connect is up"
echo ""

# ── 2. Wait for mssql-init to create kep_target ───────────────────────────────
log "Waiting for mssql-init to finish creating kep_target database…"
until [ "$(docker inspect -f '{{.State.Status}}' mssql-init 2>/dev/null)" = "exited" ]; do
    warn "mssql-init still running, waiting 3s…"
    sleep 3
done
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' mssql-init 2>/dev/null)
if [ "$EXIT_CODE" = "0" ]; then
    ok "kep_target database ready"
else
    warn "mssql-init exited with code $EXIT_CODE — check logs: docker logs mssql-init"
fi
echo ""

# ── 3. Register source connector ─────────────────────────────────────────────
log "Registering PostgreSQL → Kafka source connector…"

EXISTING=$(curl -s "$CONNECT_URL/connectors" | grep -o '"kep-postgres-source"' || true)
if [ -n "$EXISTING" ]; then
    warn "connector already exists, deleting and re-creating…"
    curl -sf -X DELETE "$CONNECT_URL/connectors/kep-postgres-source" >/dev/null
    sleep 2
fi

curl -sf -X POST "$CONNECT_URL/connectors" \
    -H "Content-Type: application/json" \
    -d @connectors/source-postgres.json | python3 -m json.tool 2>/dev/null || true
echo ""
ok "Source connector registered"
echo ""

# ── 4. Register sink connector ────────────────────────────────────────────────
log "Registering Kafka → MSSQL sink connector…"

EXISTING=$(curl -s "$CONNECT_URL/connectors" | grep -o '"kep-mssql-sink"' || true)
if [ -n "$EXISTING" ]; then
    warn "connector already exists, deleting and re-creating…"
    curl -sf -X DELETE "$CONNECT_URL/connectors/kep-mssql-sink" >/dev/null
    sleep 2
fi

curl -sf -X POST "$CONNECT_URL/connectors" \
    -H "Content-Type: application/json" \
    -d @connectors/sink-mssql.json | python3 -m json.tool 2>/dev/null || true
echo ""
ok "Sink connector registered"
echo ""

# ── 5. Print status ───────────────────────────────────────────────────────────
sleep 5
echo "── Connector status ─────────────────────────────────"
curl -s "$CONNECT_URL/connectors?expand=status" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for name, v in data.items():
    st = v.get('status', {})
    conn = st.get('connector', {})
    tasks = st.get('tasks', [])
    print(f\"  {name:35s}  connector={conn.get('state','?'):10s}  tasks={[t.get('state') for t in tasks]}\")" 2>/dev/null || \
curl -s "$CONNECT_URL/connectors"
echo ""
echo "─────────────────────────────────────────────────────"
echo ""
echo "  Kafka UI      →  http://localhost:8080"
echo "  Kafka Connect →  http://localhost:8083"
echo "  PostgreSQL    →  localhost:5432  (kep_db / kep_user / kep_password)"
echo "  MSSQL         →  localhost:1433  (kep_target / sa / KEP_Strong!Pass123)"
echo ""
echo "  Simulate live changes:  ./simulate.sh"
echo "  Verify MSSQL data:      ./verify.sh"
echo ""
