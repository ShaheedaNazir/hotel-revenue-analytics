-- =============================================================================
-- Data Quality Checks: Core hotel operations
-- Expected result: every check returns failed_rows = 0.
-- =============================================================================

-- Completed bookings must have captured payment value equal to room revenue.
SELECT
    'completed_booking_payment_reconciliation' AS test_name,
    COUNT(*) AS failed_rows
FROM core.bookings AS b
LEFT JOIN (
    SELECT booking_id, SUM(amount) AS captured_amount
    FROM core.payments
    WHERE payment_status = 'captured'
    GROUP BY booking_id
) AS p ON p.booking_id = b.booking_id
WHERE b.booking_status = 'checked_out'
  AND COALESCE(p.captured_amount, 0) <> b.room_revenue_amount;

-- Cancelled bookings must have a linked refund event.
SELECT
    'cancelled_booking_refund_exists' AS test_name,
    COUNT(*) AS failed_rows
FROM core.bookings AS b
LEFT JOIN core.payments AS p
    ON p.booking_id = b.booking_id
   AND p.payment_type = 'refund'
   AND p.payment_status = 'refunded'
WHERE b.booking_status = 'cancelled'
  AND p.payment_id IS NULL;

-- The exclusion constraint should guarantee no active room-stay overlaps.
SELECT
    'active_room_stay_overlap' AS test_name,
    COUNT(*) AS failed_rows
FROM core.bookings AS a
JOIN core.bookings AS b
    ON a.room_id = b.room_id
   AND a.booking_id < b.booking_id
   AND daterange(a.check_in_date, a.check_out_date, '[)')
       && daterange(b.check_in_date, b.check_out_date, '[)')
WHERE a.booking_status NOT IN ('cancelled', 'no_show')
  AND b.booking_status NOT IN ('cancelled', 'no_show');
