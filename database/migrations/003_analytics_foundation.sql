-- =============================================================================
-- Project      : Hotel Revenue Analytics
-- Migration    : 003_analytics_foundation.sql
-- Description  : Creates a date dimension and daily property KPI view.
-- =============================================================================

-- =============================================================================
-- 1. DATE DIMENSION
-- =============================================================================

CREATE TABLE analytics.dim_date (
    date_day DATE PRIMARY KEY,
    calendar_year SMALLINT NOT NULL,
    calendar_quarter SMALLINT NOT NULL,
    calendar_month SMALLINT NOT NULL,
    month_name TEXT NOT NULL,
    week_of_year SMALLINT NOT NULL,
    day_of_week SMALLINT NOT NULL,
    is_weekend BOOLEAN NOT NULL
);

INSERT INTO analytics.dim_date (
    date_day,
    calendar_year,
    calendar_quarter,
    calendar_month,
    month_name,
    week_of_year,
    day_of_week,
    is_weekend
)
SELECT
    d::DATE,
    EXTRACT(YEAR FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT,
    EXTRACT(MONTH FROM d)::SMALLINT,
    TO_CHAR(d, 'FMMonth'),
    EXTRACT(WEEK FROM d)::SMALLINT,
    EXTRACT(ISODOW FROM d)::SMALLINT,
    EXTRACT(ISODOW FROM d) IN (6, 7)
FROM generate_series(
    DATE '2023-01-01',
    DATE '2025-12-31',
    INTERVAL '1 day'
) AS d
ON CONFLICT (date_day) DO NOTHING;

-- =============================================================================
-- 2. DAILY PROPERTY PERFORMANCE
-- Definitions:
--   Occupancy = occupied room nights / active room inventory
--   ADR       = room revenue / occupied room nights
--   RevPAR    = room revenue / active room inventory
-- =============================================================================

CREATE OR REPLACE VIEW analytics.vw_daily_property_performance AS
WITH property_inventory AS (
    SELECT
        property_id,
        COUNT(*) FILTER (WHERE is_active) AS available_room_nights
    FROM core.rooms
    GROUP BY property_id
),
stay_room_nights AS (
    SELECT
        b.property_id,
        stay_date::DATE AS date_day,
        COUNT(*) AS occupied_room_nights,
        SUM(b.room_revenue_amount / b.stay_nights) AS gross_room_revenue
    FROM core.bookings AS b
    CROSS JOIN LATERAL generate_series(
        b.check_in_date,
        b.check_out_date - 1,
        INTERVAL '1 day'
    ) AS stay_date
    WHERE b.booking_status = 'checked_out'
    GROUP BY b.property_id, stay_date::DATE
)
SELECT
    d.date_day,
    p.property_id,
    p.property_code,
    p.property_name,
    p.city,
    i.available_room_nights,
    COALESCE(s.occupied_room_nights, 0) AS occupied_room_nights,
    COALESCE(s.gross_room_revenue, 0)::NUMERIC(14,2) AS gross_room_revenue,
    ROUND(
        100.0 * COALESCE(s.occupied_room_nights, 0) / NULLIF(i.available_room_nights, 0),
        2
    ) AS occupancy_rate_pct,
    ROUND(
        COALESCE(s.gross_room_revenue, 0) / NULLIF(s.occupied_room_nights, 0),
        2
    ) AS adr,
    ROUND(
        COALESCE(s.gross_room_revenue, 0) / NULLIF(i.available_room_nights, 0),
        2
    ) AS revpar
FROM analytics.dim_date AS d
CROSS JOIN core.properties AS p
JOIN property_inventory AS i
    ON i.property_id = p.property_id
LEFT JOIN stay_room_nights AS s
    ON s.property_id = p.property_id
   AND s.date_day = d.date_day;
