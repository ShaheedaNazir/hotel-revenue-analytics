-- Cancellation performance by booking channel and lead-time cohort.
WITH booking_cohorts AS (
    SELECT
        booking_channel,
        booking_status,
        (check_in_date - booked_at::DATE) AS lead_time_days,
        CASE
            WHEN check_in_date - booked_at::DATE <= 7 THEN '0-7 days'
            WHEN check_in_date - booked_at::DATE <= 30 THEN '8-30 days'
            WHEN check_in_date - booked_at::DATE <= 60 THEN '31-60 days'
            ELSE '61+ days'
        END AS lead_time_cohort
    FROM core.bookings
)
SELECT
    booking_channel,
    lead_time_cohort,
    COUNT(*) AS total_bookings,
    COUNT(*) FILTER (WHERE booking_status = 'cancelled') AS cancelled_bookings,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE booking_status = 'cancelled')
        / NULLIF(COUNT(*), 0),
        2
    ) AS cancellation_rate_pct,
    ROUND(AVG(lead_time_days), 1) AS avg_lead_time_days
FROM booking_cohorts
GROUP BY booking_channel, lead_time_cohort
ORDER BY booking_channel,
    CASE lead_time_cohort
        WHEN '0-7 days' THEN 1 WHEN '8-30 days' THEN 2
        WHEN '31-60 days' THEN 3 ELSE 4
    END;
