-- =============================================================================
-- Analysis: Monthly Revenue, Occupancy, ADR, and RevPAR
-- Purpose : Executive trend view across the hotel portfolio.
-- =============================================================================

SELECT
    DATE_TRUNC('month', date_day)::DATE AS month_start,
    SUM(gross_room_revenue) AS total_room_revenue,
    SUM(occupied_room_nights) AS occupied_room_nights,
    SUM(available_room_nights) AS available_room_nights,
    ROUND(
        100.0 * SUM(occupied_room_nights)
        / NULLIF(SUM(available_room_nights), 0),
        2
    ) AS occupancy_rate_pct,
    ROUND(
        SUM(gross_room_revenue)
        / NULLIF(SUM(occupied_room_nights), 0),
        2
    ) AS adr,
    ROUND(
        SUM(gross_room_revenue)
        / NULLIF(SUM(available_room_nights), 0),
        2
    ) AS revpar
FROM analytics.vw_daily_property_performance
GROUP BY DATE_TRUNC('month', date_day)::DATE
ORDER BY month_start;
