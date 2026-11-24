-- ICT371 Advanced Database - Question 7: Water Meter Billing

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
-- Tariff: first 10 units K5 each, units above 10 K8 each.
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT chk_reading_month CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES
    ('Agnes Kapambwe'), ('Boniface Simwanza'), ('Catherine Mubanga');

-- ==== (d) Trigger: reject current_reading below previous_reading ====
-- (created before the readings are loaded so the seed data is validated)
CREATE OR REPLACE FUNCTION trg_fn_check_reading() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) is below previous reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;       -- raising above aborts the statement, so nothing is stored
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- Seed: six readings covering 0 units, exactly 10 units and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100, 100),   -- 0 units
    (1, '2026-10-01', 100, 110),   -- exactly 10 units
    (2, '2026-09-01',  50,  75),   -- 25 units
    (2, '2026-10-01',  75,  80),   -- 5 units
    (3, '2026-09-01', 200, 210),   -- exactly 10 units
    (3, '2026-10-01', 210, 230);   -- 20 units

-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
-- VALUES (1, '2026-11-01', 110, 100);              -- error: trigger, row not stored

-- ==== (b) Function: fn_water_charge ====
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;

    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);   -- K50 + K8 for each unit above 10
END;
$$ LANGUAGE plpgsql;

SELECT fn_water_charge(0),    -- 0.00
       fn_water_charge(10),   -- 50.00
       fn_water_charge(25);   -- 170.00

-- ==== (c) Procedure: pr_generate_bill ====
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_units  NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT current_reading - previous_reading INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- Generate the bills (September bills are overdue, October bills are not all due yet)
CALL pr_generate_bill(1, '2026-10-15');
CALL pr_generate_bill(2, '2026-11-15');
CALL pr_generate_bill(3, '2026-10-15');
CALL pr_generate_bill(4, '2026-11-15');
CALL pr_generate_bill(5, '2026-10-15');
CALL pr_generate_bill(6, CURRENT_DATE + 14);

-- Record some payments (full payment, partial payment)
UPDATE bills SET amount_paid = charge WHERE bill_id = 2;
UPDATE bills SET amount_paid = 100    WHERE bill_id = 3;

-- CALL pr_generate_bill(1, '2026-12-01');          -- error: already has a bill
-- CALL pr_generate_bill(99, '2026-12-01');         -- error: unknown reading

-- ==== (e) View: v_overdue_bills ====
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;                     -- not fully paid

SELECT * FROM v_overdue_bills ORDER BY due_on;

-- ==== (f) Index ====
-- Justification: overdue searches only care about unpaid bills, filtered and
-- ordered by due_on. A partial index on due_on that includes only unpaid bills
-- stays small as bills get paid, and range scans on due_on use it directly.
-- The query must repeat the same condition (amount_paid < charge) for the
-- planner to be able to use the partial index.
CREATE INDEX idx_bills_unpaid_due_on
ON bills (due_on)
WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE
ORDER BY due_on;
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_refresh_receivables ====
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    -- One row per date; a rerun replaces the day's total
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                      -- rerun replaces the row
SELECT * FROM receivable_snapshot;

-- Schedule daily at 00:30 (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_receivables_daily',
    '30 0 * * *',
    $$CALL pr_refresh_receivables()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
