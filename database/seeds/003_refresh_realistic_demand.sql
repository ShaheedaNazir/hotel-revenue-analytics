-- Refresh synthetic transactional data with varied demand patterns.
-- Retains the master data; removes only generated transaction events.

TRUNCATE TABLE
    audit.booking_status_history,
    core.payments,
    core.bookings;

WITH candidate_stays AS (
    SELECT
        r.property_id,
        r.room_id,
        rt.base_nightly_rate,
        r.room_number::INTEGER AS room_number,
        gs.stay_sequence,
        DATE '2023-01-01'
            + (gs.stay_sequence * 7)
            + ((r.room_number::INTEGER) % 7) AS check_in_date
    FROM core.rooms AS r
    JOIN core.room_types AS rt ON rt.room_type_id = r.room_type_id
    CROSS JOIN LATERAL generate_series(0, 155) AS gs(stay_sequence)
),
classified_stays AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            ORDER BY c.property_id, c.room_id, c.stay_sequence
        ) AS booking_sequence,
        ABS(HASHTEXT(c.property_id::TEXT || c.stay_sequence::TEXT || c.room_number::TEXT)) % 100
            AS demand_score,
        CASE
            WHEN EXTRACT(MONTH FROM c.check_in_date) IN (6, 7, 8) THEN 82
            WHEN EXTRACT(MONTH FROM c.check_in_date) IN (4, 5, 9, 10) THEN 68
            ELSE 55
        END AS completion_threshold,
        CASE
            WHEN EXTRACT(MONTH FROM c.check_in_date) IN (6, 7, 8) THEN 94
            WHEN EXTRACT(MONTH FROM c.check_in_date) IN (4, 5, 9, 10) THEN 88
            ELSE 82
        END AS cancellation_threshold
    FROM candidate_stays AS c
)
INSERT INTO core.bookings (
    booking_reference, property_id, guest_id, room_id, booked_at,
    check_in_date, check_out_date, booking_status, booking_channel,
    adults_count, children_count, currency_code, agreed_nightly_rate,
    cancelled_at, cancellation_reason
)
SELECT
    'BKG-' || LPAD(booking_sequence::TEXT, 7, '0'),
    s.property_id,
    g.guest_id,
    s.room_id,
    (s.check_in_date - (7 + (booking_sequence % 90))::INTEGER)::TIMESTAMP
        AT TIME ZONE 'Europe/Amsterdam',
    s.check_in_date,
    s.check_in_date + (1 + (booking_sequence % 4))::INTEGER,
    CASE
        WHEN demand_score < completion_threshold THEN 'checked_out'
        WHEN demand_score < cancellation_threshold THEN 'cancelled'
        ELSE 'no_show'
    END,
    (ARRAY['direct','website','ota','corporate','walk_in','travel_agent'])
        [1 + (booking_sequence % 6)],
    1 + (booking_sequence % 3),
    CASE WHEN booking_sequence % 5 = 0 THEN 1 ELSE 0 END,
    'EUR',
    ROUND(
        base_nightly_rate * (
            CASE
                WHEN EXTRACT(MONTH FROM check_in_date) IN (6, 7, 8) THEN 1.18
                WHEN EXTRACT(MONTH FROM check_in_date) IN (4, 5, 9, 10) THEN 1.00
                ELSE 0.82
            END
            + ((booking_sequence % 15)::NUMERIC / 100)
        ),
        2
    ),
    CASE
        WHEN demand_score >= completion_threshold THEN
            (s.check_in_date - (1 + (booking_sequence % 21))::INTEGER)::TIMESTAMP
                AT TIME ZONE 'Europe/Amsterdam'
    END,
    CASE
        WHEN demand_score >= completion_threshold
             AND demand_score < cancellation_threshold
        THEN (ARRAY['guest_request','rate_change','travel_disruption','duplicate_booking'])
                 [1 + (booking_sequence % 4)]
        WHEN demand_score >= cancellation_threshold THEN 'guest_no_show'
    END
FROM classified_stays AS s
JOIN core.guests AS g ON g.guest_reference = 'GST-' || LPAD(
    (1 + (booking_sequence * 7 % 1200))::TEXT, 6, '0'
);

WITH events AS (
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
SELECT
    booking_id,
    'PAY-' || UPPER(payment_type) || '-' || REPLACE(booking_reference, 'BKG-', ''),
    payment_type, 'credit_card', 'captured',
    ROUND(room_revenue_amount * payment_share, 2), 'EUR',
    CASE WHEN payment_type = 'deposit' THEN booked_at + INTERVAL '1 hour'
         ELSE check_in_date::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam' END,
    'Adyen'
FROM events;

INSERT INTO core.payments (
    booking_id, payment_reference, payment_type, payment_method, payment_status,
    amount, currency_code, processed_at, provider_name
)
SELECT
    b.booking_id,
    'PAY-DEPOSIT-' || REPLACE(b.booking_reference, 'BKG-', ''),
    'deposit', 'credit_card', 'captured', ROUND(b.room_revenue_amount * 0.25, 2),
    'EUR', b.booked_at + INTERVAL '1 hour', 'Adyen'
FROM core.bookings AS b
WHERE b.booking_status = 'cancelled';

INSERT INTO core.payments (
    booking_id, payment_reference, payment_type, payment_method, payment_status,
    amount, currency_code, processed_at, provider_name, related_payment_id
)
SELECT
    b.booking_id,
    'PAY-REFUND-' || REPLACE(b.booking_reference, 'BKG-', ''),
    'refund', 'credit_card', 'refunded', p.amount, 'EUR',
    b.cancelled_at + INTERVAL '1 hour', 'Adyen', p.payment_id
FROM core.bookings AS b
JOIN core.payments AS p ON p.booking_id = b.booking_id
    AND p.payment_type = 'deposit' AND p.payment_status = 'captured'
WHERE b.booking_status = 'cancelled';
