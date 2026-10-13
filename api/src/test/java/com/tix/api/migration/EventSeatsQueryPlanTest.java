package com.tix.api.migration;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Regression test for the query plans behind HU 03.2.
 *
 * <p>Seeds a realistic volume of seats and asks PostgreSQL for its plan with EXPLAIN: the seat-map
 * query must resolve as an Index Only Scan (covering index), and the SOLD reconciliation must not
 * fall back to a Seq Scan (partial index). It is a regression guard: if a future migration drops or
 * changes an index, or the planner stops using it, this test fails.
 */
@Testcontainers(disabledWithoutDocker = true)
class EventSeatsQueryPlanTest {

    @Container
    static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:17")
                    .withDatabaseName("tix_test")
                    .withUsername("test")
                    .withPassword("test");

    private static JdbcTemplate jdbc;

    // Fixed UUIDs: they keep the queries readable and reproducible.
    private static final String VENUE = "00000000-0000-7000-8000-0000000000a0";
    private static final String EVENT_MAP = "00000000-0000-7000-8000-0000000000a1";
    private static final String EVENT_RECON = "00000000-0000-7000-8000-0000000000a2";
    private static final String EVENT_FILLER_1 = "00000000-0000-7000-8000-0000000000a3";
    private static final String EVENT_FILLER_2 = "00000000-0000-7000-8000-0000000000a4";
    private static final String TIER_MAP = "00000000-0000-7000-8000-0000000000b1";
    private static final String TIER_RECON = "00000000-0000-7000-8000-0000000000b2";
    private static final String TIER_FILLER_1 = "00000000-0000-7000-8000-0000000000b3";
    private static final String TIER_FILLER_2 = "00000000-0000-7000-8000-0000000000b4";

    // Data volume: without enough rows the planner prefers a Seq Scan and the test proves nothing.
    private static final int SEATS_PER_EVENT = 40_000;
    private static final int AVAILABLE_IN_MAP_EVENT = 2_000; // one "section" of the map
    private static final int SOLD_IN_RECON_EVENT = 400; // a few sold seats in the reconciled event
    private static final int SOLD_IN_FILLER_EVENT = 2_000; // sold rows of OTHER events

    @BeforeAll
    static void migrateAndSeed() {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate(); // applies V1..V6 on a clean PostgreSQL

        jdbc =
                new JdbcTemplate(
                        new DriverManagerDataSource(
                                POSTGRES.getJdbcUrl(),
                                POSTGRES.getUsername(),
                                POSTGRES.getPassword()));

        seed();

        // ANALYZE feeds the planner with statistics; VACUUM refreshes the visibility map so the
        // Index Only Scan does not visit the heap. VACUUM cannot run inside a transaction block;
        // each JdbcTemplate call autocommits, so this is fine.
        jdbc.execute("VACUUM (ANALYZE) event_seats");
    }

    private static void seed() {
        jdbc.update(
                "INSERT INTO venues (id, name, address, capacity) VALUES (?::uuid, 'Plan Arena', 'Test 1', ?)",
                VENUE,
                SEATS_PER_EVENT + 1);

        // A single physical seat layout, reused by every event.
        jdbc.update(
                """
                INSERT INTO venue_seats (venue_id, section, seat_row, seat_number)
                SELECT ?::uuid, 'A', 'R', i::text
                FROM generate_series(1, ?) i
                """,
                VENUE,
                SEATS_PER_EVENT);

        insertEvent(EVENT_MAP, "Map event");
        insertEvent(EVENT_RECON, "Reconciliation event");
        insertEvent(EVENT_FILLER_1, "Filler 1");
        insertEvent(EVENT_FILLER_2, "Filler 2");

        insertTier(TIER_MAP, EVENT_MAP, 10_000);
        insertTier(TIER_RECON, EVENT_RECON, 12_000);
        insertTier(TIER_FILLER_1, EVENT_FILLER_1, 8_000);
        insertTier(TIER_FILLER_2, EVENT_FILLER_2, 9_000);

        // Map event: a section-sized AVAILABLE slice; the rest BLOCKED.
        seedSeats(EVENT_MAP, TIER_MAP, AVAILABLE_IN_MAP_EVENT, "AVAILABLE", "BLOCKED");
        // Reconciliation event: a few SOLD seats; the rest AVAILABLE.
        seedSeats(EVENT_RECON, TIER_RECON, SOLD_IN_RECON_EVENT, "SOLD", "AVAILABLE");
        // Filler events: SOLD rows of OTHER events, so a bare status='SOLD' filter is costly.
        seedSeats(EVENT_FILLER_1, TIER_FILLER_1, SOLD_IN_FILLER_EVENT, "SOLD", "AVAILABLE");
        seedSeats(EVENT_FILLER_2, TIER_FILLER_2, SOLD_IN_FILLER_EVENT, "SOLD", "AVAILABLE");
    }

    private static void insertEvent(String eventId, String title) {
        jdbc.update(
                """
                INSERT INTO events (id, venue_id, title, status, event_date, sales_open_at)
                VALUES (?::uuid, ?::uuid, ?, 'ON_SALE', now() + interval '30 days', now())
                """,
                eventId,
                VENUE,
                title);
    }

    private static void insertTier(String tierId, String eventId, long price) {
        jdbc.update(
                """
                INSERT INTO price_tiers (id, event_id, name, price_amount)
                VALUES (?::uuid, ?::uuid, 'General', ?)
                """,
                tierId,
                eventId,
                price);
    }

    /**
     * Inserts one event_seats row per venue seat, giving {@code firstStatus} to the first {@code
     * firstN} seats (ranked by seat_number) and {@code restStatus} to the rest.
     */
    private static void seedSeats(
            String eventId, String tierId, int firstN, String firstStatus, String restStatus) {
        jdbc.update(
                """
                INSERT INTO event_seats (event_id, venue_seat_id, price_tier_id, status)
                SELECT ?::uuid, vs.id, ?::uuid,
                       CASE WHEN vs.rn <= ?::int THEN ?::varchar ELSE ?::varchar END
                FROM (SELECT id, row_number() OVER (ORDER BY seat_number::int) AS rn
                      FROM venue_seats) vs
                """,
                eventId,
                tierId,
                firstN,
                firstStatus,
                restStatus);
    }

    @Test
    @DisplayName("The seat-map query resolves with the covering Index Only Scan")
    void seatMapQueryUsesCoveringIndexOnlyScan() {
        String plan =
                explain(
                        "SELECT id, venue_seat_id FROM event_seats "
                                + "WHERE event_id = '"
                                + EVENT_MAP
                                + "' AND status = 'AVAILABLE'");

        assertThat(plan)
                .contains("Index Only Scan")
                .contains("idx_event_seats_availability")
                .doesNotContain("Seq Scan");
        // The VACUUM above refreshed the visibility map, so the index answers without the heap.
        assertThat(plan).contains("Heap Fetches: 0");
    }

    @Test
    @DisplayName("The SOLD reconciliation query does not fall back to a Seq Scan")
    void reconciliationQueryDoesNotSeqScan() {
        String plan =
                explain(
                        "SELECT id FROM event_seats WHERE status = 'SOLD' "
                                + "AND event_id = '"
                                + EVENT_RECON
                                + "'");

        assertThat(plan).doesNotContain("Seq Scan").contains("Index");
    }

    @Test
    @DisplayName("The partial index serves the SOLD scan the availability index cannot")
    void partialIndexServesTheSoldScan() {
        // No event_id: idx_event_seats_availability (leading column = event_id) cannot serve it,
        // so this is exactly the scan the B-28 partial index exists for.
        String plan = explain("SELECT id, event_id FROM event_seats WHERE status = 'SOLD'");

        assertThat(plan).doesNotContain("Seq Scan").contains("idx_event_seats_sold_reconciliation");
    }

    private String explain(String sql) {
        List<String> lines = jdbc.queryForList("EXPLAIN (ANALYZE, BUFFERS) " + sql, String.class);
        return String.join("\n", lines);
    }
}
