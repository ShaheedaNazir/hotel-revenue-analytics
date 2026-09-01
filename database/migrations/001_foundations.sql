-- =============================================================================
-- Project      : Hotel Revenue Analytics
-- Migration    : 001_foundation.sql
-- Description  : Establishes the core operational model, audit controls,
--                integrity constraints, and performance indexes.
-- Database     : PostgreSQL 18+
-- Author       : Shaheeda Nazir
-- =============================================================================
--
-- Design principles:
--   1. Layered schemas: raw, core, analytics, audit
--   2. UUID primary keys and UTC-aware timestamps
--   3. Database-enforced data quality and booking integrity
--   4. Immutable historical pricing through booking-level rate snapshots
-- =============================================================================

-- =============================================================================
-- 1. EXTENSIONS AND SCHEMA LAYERS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA raw IS
'Immutable source-style landing tables.';

COMMENT ON SCHEMA core IS
'Validated operational entities and business rules.';

COMMENT ON SCHEMA analytics IS
'Reporting-ready facts, dimensions, and KPI views.';

COMMENT ON SCHEMA audit IS
'Data-quality checks and load audit records.';

-- =============================================================================
-- 2. SHARED AUDIT FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- =============================================================================
-- 3. CORE OPERATIONAL ENTITIES
-- =============================================================================

CREATE TABLE core.properties (
    property_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_code TEXT NOT NULL UNIQUE,
    property_name TEXT NOT NULL,
    city TEXT NOT NULL,
    country_code CHAR(2) NOT NULL,
    timezone_name TEXT NOT NULL DEFAULT 'Europe/Amsterdam',
    currency_code CHAR(3) NOT NULL DEFAULT 'EUR',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_property_code_format
        CHECK (property_code ~ '^[A-Z0-9_-]+$'),
    CONSTRAINT chk_country_code_format
        CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT chk_currency_code_format
        CHECK (currency_code ~ '^[A-Z]{3}$')
);

CREATE TABLE core.room_types (
    room_type_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id UUID NOT NULL
        REFERENCES core.properties(property_id),
    room_type_code TEXT NOT NULL,
    room_type_name TEXT NOT NULL,
    base_nightly_rate NUMERIC(12,2) NOT NULL,
    max_occupancy SMALLINT NOT NULL,
    is_sellable BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_room_type_per_property
        UNIQUE (property_id, room_type_code),
    CONSTRAINT uq_room_types_property_id
        UNIQUE (property_id, room_type_id),
    CONSTRAINT chk_base_nightly_rate
        CHECK (base_nightly_rate >= 0),
    CONSTRAINT chk_max_occupancy
        CHECK (max_occupancy BETWEEN 1 AND 20)
);

CREATE TABLE core.rooms (
    room_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id UUID NOT NULL
        REFERENCES core.properties(property_id),
    room_type_id UUID NOT NULL,
    room_number TEXT NOT NULL,
    floor_number SMALLINT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_room_number_per_property
        UNIQUE (property_id, room_number),
    CONSTRAINT uq_rooms_property_id
        UNIQUE (property_id, room_id),
    CONSTRAINT fk_rooms_room_type_property
        FOREIGN KEY (property_id, room_type_id)
        REFERENCES core.room_types(property_id, room_type_id)
);

CREATE INDEX idx_rooms_property_room_type
ON core.rooms (property_id, room_type_id);

CREATE TABLE core.guests (
    guest_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guest_reference TEXT NOT NULL UNIQUE,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT,
    phone_number TEXT,
    city TEXT,
    country_code CHAR(2),
    marketing_consent BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_guest_reference_format
        CHECK (guest_reference ~ '^GST-[A-Z0-9-]+$'),
    CONSTRAINT chk_guest_country_code_format
        CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT chk_guest_email_format
        CHECK (
            email IS NULL
            OR email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
        )
);

CREATE UNIQUE INDEX uq_guests_email_ci
ON core.guests (LOWER(email))
WHERE email IS NOT NULL;

CREATE TABLE core.bookings (
    booking_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_reference TEXT NOT NULL UNIQUE,
    property_id UUID NOT NULL
        REFERENCES core.properties(property_id),
    guest_id UUID NOT NULL
        REFERENCES core.guests(guest_id),
    room_id UUID NOT NULL,

    booked_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    check_in_date DATE NOT NULL,
    check_out_date DATE NOT NULL,
    booking_status TEXT NOT NULL,
    booking_channel TEXT NOT NULL,
    adults_count SMALLINT NOT NULL DEFAULT 1,
    children_count SMALLINT NOT NULL DEFAULT 0,
    currency_code CHAR(3) NOT NULL DEFAULT 'EUR',
    agreed_nightly_rate NUMERIC(12,2) NOT NULL,

    stay_nights INTEGER GENERATED ALWAYS AS
        (check_out_date - check_in_date) STORED,

    room_revenue_amount NUMERIC(12,2) GENERATED ALWAYS AS
        ((check_out_date - check_in_date) * agreed_nightly_rate) STORED,

    cancelled_at TIMESTAMPTZ,
    cancellation_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_bookings_room_property
        FOREIGN KEY (property_id, room_id)
        REFERENCES core.rooms(property_id, room_id),

    CONSTRAINT chk_booking_reference_format
        CHECK (booking_reference ~ '^BKG-[A-Z0-9-]+$'),

    CONSTRAINT chk_booking_status
        CHECK (booking_status IN (
            'pending', 'confirmed', 'checked_in',
            'checked_out', 'cancelled', 'no_show'
        )),

    CONSTRAINT chk_booking_channel
        CHECK (booking_channel IN (
            'direct', 'website', 'ota', 'corporate',
            'walk_in', 'travel_agent'
        )),

    CONSTRAINT chk_booking_dates
        CHECK (check_out_date > check_in_date),

    CONSTRAINT chk_guest_counts
        CHECK (
            adults_count BETWEEN 1 AND 10
            AND children_count BETWEEN 0 AND 10
        ),

    CONSTRAINT chk_currency_code_format
        CHECK (currency_code ~ '^[A-Z]{3}$'),

    CONSTRAINT chk_agreed_nightly_rate
        CHECK (agreed_nightly_rate >= 0),

    CONSTRAINT chk_cancellation_details
        CHECK (
            (booking_status IN ('cancelled', 'no_show')
                AND cancelled_at IS NOT NULL)
            OR
            (booking_status NOT IN ('cancelled', 'no_show')
                AND cancelled_at IS NULL)
        )
);

CREATE INDEX idx_bookings_property_stay_dates
ON core.bookings (property_id, check_in_date, check_out_date);

CREATE INDEX idx_bookings_guest_booked_at
ON core.bookings (guest_id, booked_at DESC);

CREATE INDEX idx_bookings_status_booked_at
ON core.bookings (booking_status, booked_at DESC);

ALTER TABLE core.bookings
ADD CONSTRAINT ex_bookings_no_overlapping_active_stays
EXCLUDE USING gist (
    room_id WITH =,
    daterange(check_in_date, check_out_date, '[)') WITH &&
)
WHERE (booking_status NOT IN ('cancelled', 'no_show'));


CREATE TABLE core.payments (
    payment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID NOT NULL
        REFERENCES core.bookings(booking_id),

    payment_reference TEXT NOT NULL UNIQUE,
    payment_type TEXT NOT NULL,
    payment_method TEXT NOT NULL,
    payment_status TEXT NOT NULL,

    amount NUMERIC(12,2) NOT NULL,
    currency_code CHAR(3) NOT NULL DEFAULT 'EUR',
    processed_at TIMESTAMPTZ,
    provider_name TEXT,
    related_payment_id UUID
        REFERENCES core.payments(payment_id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_payment_reference_format
        CHECK (payment_reference ~ '^PAY-[A-Z0-9-]+$'),

    CONSTRAINT chk_payment_type
        CHECK (payment_type IN ('deposit', 'balance', 'refund', 'fee')),

    CONSTRAINT chk_payment_method
        CHECK (payment_method IN (
            'credit_card', 'debit_card', 'bank_transfer',
            'cash', 'online_wallet', 'voucher'
        )),

    CONSTRAINT chk_payment_status
        CHECK (payment_status IN (
            'pending', 'authorized', 'captured',
            'failed', 'refunded', 'voided'
        )),

    CONSTRAINT chk_payment_amount
        CHECK (amount > 0),

    CONSTRAINT chk_payment_currency_code
        CHECK (currency_code ~ '^[A-Z]{3}$')
);

CREATE INDEX idx_payments_booking_processed_at
ON core.payments (booking_id, processed_at DESC);

CREATE INDEX idx_payments_status_processed_at
ON core.payments (payment_status, processed_at DESC);


-- =============================================================================
-- 4. BOOKING STATUS AUDIT TRAIL
-- =============================================================================

CREATE TABLE audit.booking_status_history (
    booking_status_history_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID NOT NULL
        REFERENCES core.bookings(booking_id),
    previous_status TEXT,
    new_status TEXT NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    change_source TEXT NOT NULL DEFAULT 'system',
    change_reason TEXT,

    CONSTRAINT chk_status_history_values
        CHECK (
            new_status IN (
                'pending', 'confirmed', 'checked_in',
                'checked_out', 'cancelled', 'no_show'
            )
            AND (
                previous_status IS NULL
                OR previous_status IN (
                    'pending', 'confirmed', 'checked_in',
                    'checked_out', 'cancelled', 'no_show'
                )
            )
        ),

    CONSTRAINT chk_status_history_change
        CHECK (
            previous_status IS NULL
            OR previous_status <> new_status
        )
);

CREATE OR REPLACE FUNCTION audit.capture_booking_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT'
       OR OLD.booking_status IS DISTINCT FROM NEW.booking_status THEN

        INSERT INTO audit.booking_status_history (
            booking_id,
            previous_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.booking_id,
            CASE
                WHEN TG_OP = 'INSERT' THEN NULL
                ELSE OLD.booking_status
            END,
            NEW.booking_status,
            CURRENT_TIMESTAMP
        );
    END IF;

    RETURN NEW;
END;
$$;

-- =============================================================================
-- 5. AUTOMATED AUDIT TRIGGERS
-- =============================================================================

CREATE TRIGGER trg_properties_set_updated_at
BEFORE UPDATE ON core.properties
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_room_types_set_updated_at
BEFORE UPDATE ON core.room_types
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_rooms_set_updated_at
BEFORE UPDATE ON core.rooms
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_guests_set_updated_at
BEFORE UPDATE ON core.guests
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_bookings_set_updated_at
BEFORE UPDATE ON core.bookings
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_payments_set_updated_at
BEFORE UPDATE ON core.payments
FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

CREATE TRIGGER trg_bookings_capture_status_history
AFTER INSERT OR UPDATE OF booking_status ON core.bookings
FOR EACH ROW EXECUTE FUNCTION audit.capture_booking_status_change();


