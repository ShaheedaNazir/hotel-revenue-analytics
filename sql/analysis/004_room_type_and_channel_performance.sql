SELECT p.property_code, rt.room_type_name, b.booking_channel,
 COUNT(*) AS total_bookings,
 COUNT(*) FILTER (WHERE b.booking_status = 'checked_out') AS completed_bookings,
 ROUND(SUM(b.room_revenue_amount) FILTER (WHERE b.booking_status = 'checked_out'), 2) AS completed_room_revenue,
 ROUND(100.0 * COUNT(*) FILTER (WHERE b.booking_status = 'cancelled') / NULLIF(COUNT(*), 0), 2) AS cancellation_rate_pct,
 ROUND(AVG(b.agreed_nightly_rate) FILTER (WHERE b.booking_status = 'checked_out'), 2) AS avg_nightly_rate
FROM core.bookings b
JOIN core.properties p ON p.property_id = b.property_id
JOIN core.rooms r ON r.room_id = b.room_id
JOIN core.room_types rt ON rt.room_type_id = r.room_type_id
GROUP BY p.property_code, rt.room_type_name, b.booking_channel
ORDER BY completed_room_revenue DESC NULLS LAST;
