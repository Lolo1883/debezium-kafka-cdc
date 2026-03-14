-- =============================================================================
-- KEP Energy Management System — PostgreSQL (Scaleway source)
-- =============================================================================

-- Grant replication role so Debezium can open a replication slot
ALTER USER kep_user REPLICATION;

-- ── Schema ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS devices (
    id           SERIAL PRIMARY KEY,
    device_id    VARCHAR(50)  UNIQUE NOT NULL,
    name         VARCHAR(100) NOT NULL,
    location     VARCHAR(150),
    device_type  VARCHAR(50),          -- smart_meter | clamp_meter | solar_inverter
    installed_at TIMESTAMP,
    is_active    BOOLEAN      DEFAULT TRUE,
    created_at   TIMESTAMP    DEFAULT NOW(),
    updated_at   TIMESTAMP    DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS energy_readings (
    id                BIGSERIAL PRIMARY KEY,
    device_id         VARCHAR(50)    NOT NULL REFERENCES devices(device_id),
    reading_timestamp TIMESTAMP      NOT NULL,
    voltage_v         DECIMAL(10,3),
    current_a         DECIMAL(10,3),
    power_kw          DECIMAL(10,4),
    energy_kwh        DECIMAL(12,6),
    frequency_hz      DECIMAL(6,3),
    power_factor      DECIMAL(4,3),
    temperature_c     DECIMAL(6,2),
    created_at        TIMESTAMP      DEFAULT NOW()
);

CREATE INDEX idx_er_device_time ON energy_readings(device_id, reading_timestamp DESC);
CREATE INDEX idx_er_timestamp   ON energy_readings(reading_timestamp DESC);

-- ── Seed data — devices ───────────────────────────────────────────────────────

INSERT INTO devices (device_id, name, location, device_type, installed_at) VALUES
  ('DEV-001', 'Main Building Meter',   'Scaleway DC – Main Distribution', 'smart_meter',    NOW() - INTERVAL '1 year'),
  ('DEV-002', 'Server Room Panel',     'Scaleway DC – Server Room B',     'smart_meter',    NOW() - INTERVAL '8 months'),
  ('DEV-003', 'Cooling System',        'Scaleway DC – HVAC Zone 1',       'clamp_meter',    NOW() - INTERVAL '6 months'),
  ('DEV-004', 'UPS System A',          'Scaleway DC – UPS Room',          'smart_meter',    NOW() - INTERVAL '10 months'),
  ('DEV-005', 'Solar Array Gateway',   'Scaleway DC – Rooftop',           'solar_inverter', NOW() - INTERVAL '4 months');

-- ── Seed data — historical readings (last 24 h, 15-min interval per device) ──

DO $$
DECLARE
    v_device_id    VARCHAR(50);
    v_ts           TIMESTAMP;
    v_base_voltage DECIMAL(10,3);
    v_base_current DECIMAL(10,3);
BEGIN
    FOR v_device_id IN SELECT device_id FROM devices LOOP
        v_ts := NOW() - INTERVAL '24 hours';

        -- Give each device its own electrical profile
        CASE v_device_id
            WHEN 'DEV-001' THEN v_base_voltage := 230.0; v_base_current := 45.0;
            WHEN 'DEV-002' THEN v_base_voltage := 230.0; v_base_current := 32.0;
            WHEN 'DEV-003' THEN v_base_voltage := 400.0; v_base_current := 18.0;
            WHEN 'DEV-004' THEN v_base_voltage := 230.0; v_base_current := 25.0;
            WHEN 'DEV-005' THEN v_base_voltage := 380.0; v_base_current := 12.0;
        END CASE;

        WHILE v_ts <= NOW() LOOP
            INSERT INTO energy_readings (
                device_id, reading_timestamp,
                voltage_v, current_a, power_kw, energy_kwh,
                frequency_hz, power_factor, temperature_c
            ) VALUES (
                v_device_id,
                v_ts,
                ROUND((v_base_voltage + (random() - 0.5) * 5)::numeric,           3),
                ROUND((v_base_current + (random() - 0.5) * 3)::numeric,           3),
                ROUND((v_base_voltage * v_base_current * 0.95 / 1000
                       + (random() - 0.5) * 0.5)::numeric,                        4),
                ROUND((v_base_voltage * v_base_current * 0.95 / 1000 * 0.25
                       + random() * 0.1)::numeric,                                 6),
                ROUND((50.0 + (random() - 0.5) * 0.2)::numeric,                   3),
                ROUND((0.92 + (random() - 0.5) * 0.05)::numeric,                  3),
                ROUND((22.0 + (random() - 0.5) * 5)::numeric,                     2)
            );
            v_ts := v_ts + INTERVAL '15 minutes';
        END LOOP;
    END LOOP;
END $$;

-- ── Logical replication publication ──────────────────────────────────────────
-- Debezium will consume from this publication via pgoutput plugin.
-- publication.autocreate.mode=disabled is set in the connector config, so we
-- create it here explicitly.

CREATE PUBLICATION kep_publication FOR TABLE devices, energy_readings;
