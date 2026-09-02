WITH booking_kpis AS (
 SELECT COUNT(*) total_bookings,
 COUNT(*) FILTER (WHERE booking_status = 'checked_out') completed_bookings,
 COUNT(*) FILTER (WHERE booking_status = 'cancelled') cancelled_bookings,
 SUM(room_revenue_amount) FILTER (WHERE booking_status = 'checked_out') gross_room_revenue,
 COUNT(DISTINCT guest_id) FILTER (WHERE booking_status = 'checked_out') active_guests
 FROM core.bookings
), payment_kpis AS (
 SELECT SUM(amount) FILTER (WHERE payment_status = 'captured') captured_cash,
 SUM(amount) FILTER (WHERE payment_status = 'refunded') refunded_cash
 FROM core.payments
)
SELECT b.total_bookings, b.completed_bookings, b.cancelled_bookings,
 ROUND(100.0 * b.cancelled_bookings / NULLIF(b.total_bookings,0),2) cancellation_rate_pct,
 ROUND(b.gross_room_revenue,2) gross_room_revenue,
 ROUND(p.captured_cash-p.refunded_cash,2) net_cash_collected,
 b.active_guests,
 ROUND(b.gross_room_revenue / NULLIF(b.active_guests,0),2) revenue_per_active_guest
FROM booking_kpis b CROSS JOIN payment_kpis p;
