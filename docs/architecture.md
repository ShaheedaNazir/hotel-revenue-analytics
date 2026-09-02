# Architecture

## Data layers

The raw schema is reserved for source ingestion. Core stores validated hotel operations. Analytics supplies KPI-ready views and dimensions. Audit captures status history and quality controls.

## Core relationships

One property has many room types and rooms. A guest can make many bookings. Each booking belongs to one room and can produce multiple payment events.

## Integrity controls

- UUID primary keys and timestamp audit fields
- Foreign keys and business-rule checks
- Exclusion constraint preventing active overlapping room stays
- Trigger-generated booking status history
- Synthetic data only; no real customer information
