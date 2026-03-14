#!/usr/bin/env bash
# =============================================================================
# Simulate live KEP energy events so you can watch CDC in action
# =============================================================================

set -euo pipefail

DEVICES=('DEV-001' 'DEV-002' 'DEV-003' 'DEV-004' 'DEV-005')
ROUNDS=${1:-10}

echo "Inserting $ROUNDS live readings into PostgreSQL (watch Kafka UI & MSSQL)…"
echo ""

for i in $(seq 1 "$ROUNDS"); do
    DEV=${DEVICES[$((RANDOM % 5))]}

    docker exec kep-postgres psql -U kep_user -d kep_db -q -c "
        INSERT INTO energy_readings
            (device_id, reading_timestamp, voltage_v, current_a, power_kw,
             energy_kwh, frequency_hz, power_factor, temperature_c)
        VALUES (
            '$DEV',
            NOW(),
            ROUND((230.0 + (random()-0.5)*6)::numeric,  3),
            ROUND((40.0  + (random()-0.5)*4)::numeric,  3),
            ROUND((10.0  + (random()-0.5)*2)::numeric,  4),
            ROUND((2.5   + random()*0.5)::numeric,       6),
            ROUND((50.0  + (random()-0.5)*0.2)::numeric, 3),
            ROUND((0.90  + random()*0.08)::numeric,      3),
            ROUND((21.0  + random()*6)::numeric,         2)
        );"

    echo "  [$i/$ROUNDS] Inserted reading for $DEV at $(date '+%H:%M:%S')"
    sleep 2
done

echo ""
echo "Done. Run ./verify.sh to compare row counts."
echo ""

# ── Optional: simulate a device update ───────────────────────────────────────
echo "Simulating device update (DEV-001 location change)…"
docker exec kep-postgres psql -U kep_user -d kep_db -q -c "
    UPDATE devices
    SET location   = 'Scaleway DC – Main Distribution (updated)',
        updated_at = NOW()
    WHERE device_id = 'DEV-001';"
echo "  Device DEV-001 updated."
echo ""

# ── Optional: simulate a soft delete (is_active = false) ─────────────────────
echo "Simulating device decommission (DEV-005 → inactive)…"
docker exec kep-postgres psql -U kep_user -d kep_db -q -c "
    UPDATE devices SET is_active = FALSE, updated_at = NOW()
    WHERE device_id = 'DEV-005';"
echo "  Device DEV-005 marked inactive."
echo ""
