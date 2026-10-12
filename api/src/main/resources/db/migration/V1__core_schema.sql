-- =============================================================================
-- V1__core_schema.sql  ·  Ticket Platform
-- Target: api/src/main/resources/db/migration/
-- Tested on PostgreSQL 17. Compatible with 18 (on 18 you can replace
-- generate_uuid_v7() with the native uuidv7()).
-- Flyway migrations must connect DIRECTLY to PostgreSQL (not through PgBouncer).
-- Tables arriving in V2+: payments, webhook_events, idempotency_keys,
-- outbox_events, processed_events, tickets, refresh_tokens.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- UUID v7 (RFC 9562): 48 bits of timestamp (ms) + version 7 + variant + random.
-- Starts from a UUID v4 (which already carries the correct variant), overlays the
-- timestamp and forces version 7. gen_random_uuid() is native since PostgreSQL 13
-- (no pgcrypto needed).
CREATE OR REPLACE FUNCTION generate_uuid_v7() RETURNS uuid AS $$
  SELECT encode(
    set_bit(
      set_bit(
        overlay(uuid_send(gen_random_uuid())
                PLACING substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
                FROM 1 FOR 6),
        52, 1),
      53, 1),
    'hex')::uuid;
$$ LANGUAGE sql VOLATILE;

-- Self-check: if the function generated invalid UUIDs, the migration fails here
-- and not later, with broken inserts in production.
DO $$
DECLARE
  u uuid;
BEGIN
  FOR i IN 1..2000 LOOP
    u := generate_uuid_v7();
    IF substr(u::text, 15, 1) <> '7' OR substr(u::text, 20, 1) NOT IN ('8', '9', 'a', 'b') THEN
      RAISE EXCEPTION 'generate_uuid_v7() generates invalid UUIDs: %', u;
    END IF;
  END LOOP;
END $$;

-- Keeps updated_at without relying on the application.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Financial history is never deleted: orders change state, they are never removed.
-- (TRUNCATE does not fire this trigger: it is used to clean test environments.)
CREATE OR REPLACE FUNCTION forbid_delete() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'DELETE is not allowed on %: use state changes', TG_TABLE_NAME
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 1. MASTER DATA
-- -----------------------------------------------------------------------------
CREATE TABLE venues (
  id         uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  name       varchar(255) NOT NULL,
  address    text         NOT NULL,
  capacity   integer      NOT NULL CHECK (capacity > 0),
  created_at timestamptz  NOT NULL DEFAULT now(),
  updated_at timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id             uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  email          varchar(255) NOT NULL,
  password_hash  varchar(255) NOT NULL,   -- includes the algorithm prefix: {argon2}..., {bcrypt}...
  full_name      varchar(255) NOT NULL,
  role           varchar(20)  NOT NULL DEFAULT 'CUSTOMER'
                 CHECK (role IN ('CUSTOMER', 'ORGANIZER', 'SUPPORT', 'ADMIN')),
  email_verified boolean      NOT NULL DEFAULT false,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now()
);
-- Case-insensitive uniqueness. The app must normalize to lowercase when saving and searching.
CREATE UNIQUE INDEX ux_users_email_lower ON users (lower(email));

-- -----------------------------------------------------------------------------
-- 2. EVENTS, PRICES AND INVENTORY
-- -----------------------------------------------------------------------------
CREATE TABLE events (
  id            uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  venue_id      uuid         NOT NULL REFERENCES venues(id) ON DELETE RESTRICT,
  title         varchar(255) NOT NULL,
  description   text,
  status        varchar(20)  NOT NULL DEFAULT 'DRAFT'
                CHECK (status IN ('DRAFT', 'PUBLISHED', 'ON_SALE', 'SOLD_OUT', 'CANCELLED', 'COMPLETED')),
  event_date    timestamptz  NOT NULL,
  sales_open_at timestamptz  NOT NULL,
  created_at    timestamptz  NOT NULL DEFAULT now(),
  updated_at    timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_events_sales_before_event CHECK (sales_open_at <= event_date)
);
-- (No available-seat counter: it would be a hot row on every sale.
--  It is computed with count(*) over event_seats or projected in Redis.)

CREATE TABLE price_tiers (
  id           uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  event_id     uuid         NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
  name         varchar(100) NOT NULL,
  price_amount bigint       NOT NULL CHECK (price_amount >= 0),   -- minor units (cents)
  currency     char(3)      NOT NULL DEFAULT 'ARS' CHECK (currency ~ '^[A-Z]{3}$'),
  created_at   timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT uk_price_tiers_event_name UNIQUE (event_id, name),
  CONSTRAINT uk_price_tiers_id_event   UNIQUE (id, event_id)       -- enables composite FKs
);

-- Physical venue seat: static, without sale state.
CREATE TABLE venue_seats (
  id          uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  venue_id    uuid        NOT NULL REFERENCES venues(id) ON DELETE RESTRICT,
  section     varchar(50) NOT NULL,
  seat_row    varchar(10) NOT NULL,
  seat_number varchar(10) NOT NULL,
  CONSTRAINT uk_venue_seats_location UNIQUE (venue_id, section, seat_row, seat_number)
);

-- Inventory PER EVENT: what is actually sold.
-- There is no RESERVED state: temporary holds live in Redis (TTL 10 min);
-- the database only knows available / sold / blocked.
CREATE TABLE event_seats (
  id            uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  event_id      uuid        NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
  venue_seat_id uuid        NOT NULL REFERENCES venue_seats(id) ON DELETE RESTRICT,
  price_tier_id uuid        NOT NULL,
  status        varchar(20) NOT NULL DEFAULT 'AVAILABLE'
                CHECK (status IN ('AVAILABLE', 'SOLD', 'BLOCKED')),
  version       integer     NOT NULL DEFAULT 0,      -- optimistic control (JPA @Version)
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uk_event_seats_event_venue_seat UNIQUE (event_id, venue_seat_id),
  CONSTRAINT uk_event_seats_id_event         UNIQUE (id, event_id),
  -- the seat tier must belong to the SAME event
  CONSTRAINT fk_event_seats_tier FOREIGN KEY (price_tier_id, event_id)
    REFERENCES price_tiers (id, event_id) ON DELETE RESTRICT
);

-- Availability map query per event (Index-Only Scan; requires a daily VACUUM).
CREATE INDEX idx_event_seats_availability ON event_seats (event_id, status) INCLUDE (id, venue_seat_id);
CREATE INDEX idx_event_seats_venue_seat   ON event_seats (venue_seat_id);
CREATE INDEX idx_event_seats_tier         ON event_seats (price_tier_id);

-- -----------------------------------------------------------------------------
-- 3. ORDERS AND ITEMS
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
  id          uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  user_id     uuid        NOT NULL REFERENCES users(id)  ON DELETE RESTRICT,
  event_id    uuid        NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
  status      varchar(20) NOT NULL DEFAULT 'PENDING_PAYMENT'
              CHECK (status IN ('PENDING_PAYMENT', 'PAID', 'FULFILLED', 'EXPIRED',
                                'CANCELLED', 'PAYMENT_FAILED', 'REFUNDED')),
  total_amount bigint     NOT NULL CHECK (total_amount >= 0),
  currency    char(3)     NOT NULL DEFAULT 'ARS' CHECK (currency ~ '^[A-Z]{3}$'),
  expires_at  timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uk_orders_id_event UNIQUE (id, event_id)
);

CREATE TABLE order_items (
  id            uuid PRIMARY KEY DEFAULT generate_uuid_v7(),
  order_id      uuid        NOT NULL,
  event_id      uuid        NOT NULL,
  event_seat_id uuid        NOT NULL,
  price_tier_id uuid        NOT NULL,        -- tier in effect at purchase (copied from the seat)
  price_paid    bigint      NOT NULL CHECK (price_paid >= 0),   -- immutable (see trigger)
  currency      char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  released_at   timestamptz,                 -- NULL = active item (holds the seat)
  release_reason varchar(20)
                CHECK (release_reason IN ('EXPIRED', 'CANCELLED', 'PAYMENT_FAILED', 'REFUNDED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_order_items_release_consistency
    CHECK ((released_at IS NULL) = (release_reason IS NULL)),
  -- the item belongs to an order AND to a seat of the SAME event
  CONSTRAINT fk_order_items_order FOREIGN KEY (order_id, event_id)
    REFERENCES orders (id, event_id) ON DELETE RESTRICT,
  CONSTRAINT fk_order_items_seat FOREIGN KEY (event_seat_id, event_id)
    REFERENCES event_seats (id, event_id) ON DELETE RESTRICT,
  CONSTRAINT fk_order_items_tier FOREIGN KEY (price_tier_id, event_id)
    REFERENCES price_tiers (id, event_id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- 4. INDEXES AND ANTI-OVERSELLING DEFENSE
-- -----------------------------------------------------------------------------
CREATE INDEX idx_events_venue_id        ON events (venue_id);
CREATE INDEX idx_events_status_date     ON events (status, event_date);
CREATE INDEX idx_price_tiers_event_id   ON price_tiers (event_id);
CREATE INDEX idx_orders_user_created    ON orders (user_id, created_at DESC);
CREATE INDEX idx_orders_event_id        ON orders (event_id);
CREATE INDEX idx_order_items_order_id   ON order_items (order_id);
CREATE INDEX idx_order_items_seat_id    ON order_items (event_seat_id);

-- Unpaid-order expiration job (only indexes the pending ones).
CREATE INDEX idx_orders_pending_expiry  ON orders (expires_at) WHERE status = 'PENDING_PAYMENT';

-- LAST LINE OF DEFENSE: a seat of an event cannot have two active items,
-- even if Redis loses a lock during a failover.
CREATE UNIQUE INDEX ux_order_items_active_seat ON order_items (event_seat_id) WHERE released_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5. TRIGGERS
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_venues_updated_at      BEFORE UPDATE ON venues      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated_at       BEFORE UPDATE ON users       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_events_updated_at      BEFORE UPDATE ON events      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_event_seats_updated_at BEFORE UPDATE ON event_seats FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at      BEFORE UPDATE ON orders      FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- order_items immutability: only released_at / release_reason may change,
-- and a released item cannot be reactivated.
CREATE OR REPLACE FUNCTION enforce_order_item_immutability() RETURNS trigger AS $$
BEGIN
  IF NEW.order_id      IS DISTINCT FROM OLD.order_id
  OR NEW.event_id      IS DISTINCT FROM OLD.event_id
  OR NEW.event_seat_id IS DISTINCT FROM OLD.event_seat_id
  OR NEW.price_tier_id IS DISTINCT FROM OLD.price_tier_id
  OR NEW.price_paid    IS DISTINCT FROM OLD.price_paid
  OR NEW.currency      IS DISTINCT FROM OLD.currency
  OR NEW.created_at    IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'order_items: only released_at and release_reason can be modified'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF OLD.released_at IS NOT NULL
     AND (NEW.released_at IS DISTINCT FROM OLD.released_at
          OR NEW.release_reason IS DISTINCT FROM OLD.release_reason) THEN
    RAISE EXCEPTION 'order_items: a released item cannot be modified or reactivated'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_items_immutable
  BEFORE UPDATE ON order_items FOR EACH ROW EXECUTE FUNCTION enforce_order_item_immutability();

CREATE TRIGGER trg_order_items_no_delete BEFORE DELETE ON order_items FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER trg_orders_no_delete      BEFORE DELETE ON orders      FOR EACH ROW EXECUTE FUNCTION forbid_delete();

-- -----------------------------------------------------------------------------
-- 6. AUTOVACUUM of the hot table (required for Index-Only Scan)
-- -----------------------------------------------------------------------------
ALTER TABLE event_seats SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  fillfactor = 90
);
