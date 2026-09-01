# Hotel Revenue Analytics

A PostgreSQL analytics engineering project that models hotel operations and
transforms booking and payment events into reliable revenue, occupancy,
cancellation, and guest-behaviour insights.

## Project status

In progress — database foundation and operational data model established.

## Business questions

- Which properties, room types, and channels drive revenue?
- What are the cancellation rate and booking lead-time patterns?
- How do occupancy, ADR, and RevPAR change over time?
- Which guests return, and what is their lifetime value?
- Where do payment and booking data-quality issues occur?

## Architecture

```text
raw       → source-style landing data
core      → validated operational entities and business rules
analytics → reporting-ready models and KPI views
audit     → status history and data-quality controls