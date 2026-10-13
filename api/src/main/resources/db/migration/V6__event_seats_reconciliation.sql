-- =============================================================================
-- V6__event_seats_reconciliation.sql
-- Target: api/src/main/resources/db/migration/
--
-- HU 03.2 / task 7 (B-28): partial index for the SOLD-seat reconciliation.
--
-- The reconciliation job (HU 04.5) queries WHERE status = 'SOLD' AND event_id = $1
-- to rebuild the sold-seat set in Redis. idx_event_seats_availability starts with
-- event_id, so it cannot serve a scan restricted to the sold rows of a single event
-- (and a bare status filter would Seq Scan the whole table). This partial index only
-- covers SOLD rows -- a small, shrinking subset -- so the event-bounded
-- reconciliation scans exactly what it needs.
--
-- Migration numbering: V2-V5 are reserved by B-37 for refresh_tokens, audit_log,
-- payments and outbox_events; new non-reserved migrations start at V6.
-- =============================================================================

CREATE INDEX idx_event_seats_sold_reconciliation
  ON event_seats (id, event_id)
  WHERE status = 'SOLD';