-- =============================================================================
-- Analysis: Repeat guests, retention, and customer lifetime value
-- =============================================================================

WITH guest_metrics AS (
    SELECT
        g.guest_id,
        g.guest_reference,
        g.city,
        COUNT(b.booking_id) FILTER (
            WHERE b.booking_status = 'checked_out'
        ) AS completed_stays,
        COALESCE(SUM(b.room_revenue_amount) FILTER (
            WHERE b.booking_status = 'checked_out'
        ), 0) AS lifetime_room_revenue,
        MIN(b.check_in_date) FILTER (
            WHERE b.booking_status = 'checked_out'
        ) AS first_stay_date,
        MAX(b.check_in_date) FILTER (
            WHERE b.booking_status = 'checked_out'
        ) AS most_recent_stay_date
    FROM core.guests AS g
    LEFT JOIN core.bookings AS b
        ON b.guest_id = g.guest_id
    GROUP BY g.guest_id, g.guest_reference, g.city
)
, segmented_guests AS (
SELECT
    CASE
        WHEN completed_stays = 0 THEN 'No completed stay'
        WHEN completed_stays = 1 THEN 'One-time guest'
        WHEN completed_stays BETWEEN 2 AND 4 THEN 'Repeat guest'
        ELSE 'Loyal guest'
    END AS guest_segment,
    CASE
        WHEN completed_stays = 0 THEN 1
        WHEN completed_stays = 1 THEN 2
        WHEN completed_stays BETWEEN 2 AND 4 THEN 3
        ELSE 4
    END AS segment_sort,
    lifetime_room_revenue
FROM guest_metrics
)
SELECT
    guest_segment,
    COUNT(*) AS guests,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (),
        2
    ) AS guest_share_pct,
    ROUND(AVG(lifetime_room_revenue), 2) AS avg_customer_lifetime_value,
    ROUND(SUM(lifetime_room_revenue), 2) AS total_lifetime_room_revenue
FROM segmented_guests
GROUP BY guest_segment, segment_sort
ORDER BY segment_sort;
