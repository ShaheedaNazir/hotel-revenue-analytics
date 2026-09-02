-- =============================================================================
-- Project: Hotel Revenue Analytics | Seed: 002_synthetic_operational_data.sql
-- Purpose: Deterministic synthetic Netherlands hotel data. No real customer data.
-- =============================================================================

-- 1. PROPERTY AND ROOM MASTER DATA
INSERT INTO core.properties
    (property_code, property_name, city, country_code, timezone_name, currency_code)
VALUES
    ('AMS-CEN', 'Canal House Amsterdam', 'Amsterdam', 'NL', 'Europe/Amsterdam', 'EUR'),
    ('RTM-HBR', 'Harbour View Rotterdam', 'Rotterdam', 'NL', 'Europe/Amsterdam', 'EUR'),
    ('UTR-CTR', 'Dom Square Utrecht', 'Utrecht', 'NL', 'Europe/Amsterdam', 'EUR')
ON CONFLICT (property_code) DO NOTHING;

INSERT INTO core.room_types
    (property_id, room_type_code, room_type_name, base_nightly_rate, max_occupancy)
SELECT p.property_id, v.code, v.name, v.rate, v.occupancy
FROM (VALUES
    ('AMS-CEN', 'STD', 'Standard King', 155.00, 2),
    ('AMS-CEN', 'DLX', 'Deluxe Canal View', 245.00, 2),
    ('AMS-CEN', 'STE', 'Executive Suite', 425.00, 3),
    ('RTM-HBR', 'STD', 'Standard Queen', 125.00, 2),
    ('RTM-HBR', 'DLX', 'Deluxe Harbour View', 195.00, 2),
    ('RTM-HBR', 'FAM', 'Family Room', 235.00, 4),
    ('UTR-CTR', 'STD', 'Standard Double', 135.00, 2),
    ('UTR-CTR', 'DLX', 'Deluxe City View', 205.00, 2),
    ('UTR-CTR', 'STE', 'Junior Suite', 315.00, 3)
) AS v(property_code, code, name, rate, occupancy)
JOIN core.properties AS p ON p.property_code = v.property_code
ON CONFLICT (property_id, room_type_code) DO NOTHING;

WITH inventory AS (
    SELECT rt.property_id, rt.room_type_id,
           ROW_NUMBER() OVER (
               PARTITION BY rt.property_id ORDER BY rt.room_type_code, gs.n
           ) AS room_sequence
    FROM core.room_types AS rt
    CROSS JOIN LATERAL generate_series(1, 12) AS gs(n)
)
INSERT INTO core.rooms (property_id, room_type_id, room_number, floor_number)
SELECT property_id, room_type_id, (100 + room_sequence)::TEXT,
       ((room_sequence - 1) / 10 + 1)::SMALLINT
FROM inventory
ON CONFLICT (property_id, room_number) DO NOTHING;

-- 2. SYNTHETIC GUEST PROFILES
INSERT INTO core.guests
    (guest_reference, first_name, last_name, email, city, country_code, marketing_consent)
SELECT
    'GST-' || LPAD(gs::TEXT, 6, '0'),
    (ARRAY['Emma','Noah','Sofia','Liam','Mila','Lucas'])[1 + (gs % 6)],
    (ARRAY['Jansen','De Vries','Bakker','Visser','Smit','Mulder'])[1 + ((gs / 6) % 6)],
    'guest.' || gs || '@example.test',
    (ARRAY['Amsterdam','Rotterdam','Utrecht','The Hague','Eindhoven'])[1 + (gs % 5)],
    'NL', (gs % 3 = 0)
FROM generate_series(1, 1200) AS gs
ON CONFLICT (guest_reference) DO NOTHING;

-- 3. BOOKING HISTORY: room stays are spaced to prevent overlap.
WITH booking_seed AS (
    SELECT r.property_id, r.room_id, rt.base_nightly_rate, gs.stay_sequence,
           ROW_NUMBER() OVER (
               ORDER BY r.property_id, r.room_id, gs.stay_sequence
           ) AS booking_sequence,
           DATE '2023-01-01' + (gs.stay_sequence * 35)
               + ((r.room_number::INTEGER) % 10) AS check_in_date,
           CASE
               WHEN (gs.stay_sequence + r.room_number::INTEGER) % 11 = 0 THEN 'cancelled'
               WHEN (gs.stay_sequence + r.room_number::INTEGER) % 17 = 0 THEN 'no_show'
               ELSE 'checked_out'
           END AS booking_status
    FROM core.rooms AS r
    JOIN core.room_types AS rt ON rt.room_type_id = r.room_type_id
    CROSS JOIN LATERAL generate_series(0, 29) AS gs(stay_sequence)
)
INSERT INTO core.bookings (
    booking_reference, property_id, guest_id, room_id, booked_at, check_in_date,
    check_out_date, booking_status, booking_channel, adults_count, children_count,
    currency_code, agreed_nightly_rate, cancelled_at, cancellation_reason
)
SELECT
    'BKG-' || LPAD(bs.booking_sequence::TEXT, 7, '0'), bs.property_id, g.guest_id,
    bs.room_id,
    (bs.check_in_date - (14 + (bs.booking_sequence % 60))::INTEGER)::TIMESTAMP
        AT TIME ZONE 'Europe/Amsterdam',
    bs.check_in_date,
    bs.check_in_date + (1 + (bs.booking_sequence % 5))::INTEGER,
    bs.booking_status,
    (ARRAY['direct','website','ota','corporate','walk_in','travel_agent'])
        [1 + (bs.booking_sequence % 6)],
    1 + (bs.booking_sequence % 3),
    CASE WHEN bs.booking_sequence % 5 = 0 THEN 1 ELSE 0 END,
    'EUR',
    ROUND(bs.base_nightly_rate * (0.85 + ((bs.booking_sequence % 31)::NUMERIC / 100)), 2),
    CASE WHEN bs.booking_status IN ('cancelled', 'no_show')
         THEN (bs.check_in_date - (1 + (bs.booking_sequence % 21))::INTEGER)::TIMESTAMP
             AT TIME ZONE 'Europe/Amsterdam' END,
    CASE WHEN bs.booking_status = 'cancelled'
         THEN (ARRAY['guest_request','rate_change','travel_disruption','duplicate_booking'])
                 [1 + (bs.booking_sequence % 4)]
         WHEN bs.booking_status = 'no_show' THEN 'guest_no_show' END
FROM booking_seed AS bs
JOIN core.guests AS g ON g.guest_reference = 'GST-' || LPAD(
    (1 + (bs.booking_sequence * 7 % 1200))::TEXT, 6, '0'
)
ON CONFLICT (booking_reference) DO NOTHING;

-- 4. PAYMENT EVENTS
WITH payment_events AS (
    SELECT b.booking_id, b.booking_reference, b.booked_at, b.check_in_date,
           b.room_revenue_amount, e.payment_type, e.payment_share
    FROM core.bookings AS b
    CROSS JOIN LATERAL (
        VALUES ('deposit', 0.25::NUMERIC), ('balance', 0.75::NUMERIC)
    ) AS e(payment_type, payment_share)
    WHERE b.booking_status = 'checked_out'
)
INSERT INTO core.payments (
    booking_id, payment_reference, payment_type, payment_method, payment_status,
    amount, currency_code, processed_at, provider_name
)
SELECT booking_id,
       'PAY-' || UPPER(payment_type) || '-' || REPLACE(booking_reference, 'BKG-', ''),
       payment_type,
       CASE WHEN ABS(HASHTEXT(booking_reference)) % 3 = 0 THEN 'credit_card'
            WHEN ABS(HASHTEXT(booking_reference)) % 3 = 1 THEN 'debit_card'
            ELSE 'bank_transfer' END,
       'captured', ROUND(room_revenue_amount * payment_share, 2), 'EUR',
       CASE WHEN payment_type = 'deposit' THEN booked_at + INTERVAL '1 hour'
            ELSE check_in_date::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam' END,
       'Adyen'
FROM payment_events
ON CONFLICT (payment_reference) DO NOTHING;

INSERT INTO core.payments (
    booking_id, payment_reference, payment_type, payment_method, payment_status,
    amount, currency_code, processed_at, provider_name
)
SELECT b.booking_id, 'PAY-DEPOSIT-' || REPLACE(b.booking_reference, 'BKG-', ''),
       'deposit', 'credit_card', 'captured', ROUND(b.room_revenue_amount * 0.25, 2),
       'EUR', b.booked_at + INTERVAL '1 hour', 'Adyen'
FROM core.bookings AS b
WHERE b.booking_status = 'cancelled'
ON CONFLICT (payment_reference) DO NOTHING;

INSERT INTO core.payments (
    booking_id, payment_reference, payment_type, payment_method, payment_status,
    amount, currency_code, processed_at, provider_name, related_payment_id
)
SELECT b.booking_id, 'PAY-REFUND-' || REPLACE(b.booking_reference, 'BKG-', ''),
       'refund', 'credit_card', 'refunded', p.amount, 'EUR',
       b.cancelled_at + INTERVAL '1 hour', 'Adyen', p.payment_id
FROM core.bookings AS b
JOIN core.payments AS p ON p.booking_id = b.booking_id
    AND p.payment_type = 'deposit' AND p.payment_status = 'captured'
WHERE b.booking_status = 'cancelled'
ON CONFLICT (payment_reference) DO NOTHING;
