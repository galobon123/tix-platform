package com.tix.api.migration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Tests the V1__core_schema.sql schema against a real PostgreSQL. It does not start the Spring
 * context: just Flyway + JDBC, so it is fast and does not depend on the app's security, Redis or
 * Kafka configuration.
 */
@Testcontainers(disabledWithoutDocker = true)
class FlywayMigrationTest {

    // Align the version with production (docker-compose uses postgres:17).
    @Container
    static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:17")
                    .withDatabaseName("tix_test")
                    .withUsername("test")
                    .withPassword("test");

    private static DriverManagerDataSource dataSource;
    private static JdbcTemplate jdbc;

    // IDs from test-fixtures.sql
    private static final String EVENT_1 = "00000000-0000-7000-8000-0000000000e1";
    private static final String EVENT_2 = "00000000-0000-7000-8000-0000000000e2";
    private static final String TIER_1 = "00000000-0000-7000-8000-0000000000b1";
    private static final String TIER_2 = "00000000-0000-7000-8000-0000000000b2";
    private static final String SEAT_1_EVENT_1 =
            "00000000-0000-7000-8000-0000000000d1"; // seat c1 in event 1
    private static final String SEAT_1_EVENT_2 =
            "00000000-0000-7000-8000-0000000000d2"; // SAME seat c1 in event 2
    private static final String SEAT_3_EVENT_2 =
            "00000000-0000-7000-8000-0000000000d3"; // another seat, event 2
    private static final String ORDER_1 = "00000000-0000-7000-8000-0000000000f1"; // event 1
    private static final String ORDER_2 = "00000000-0000-7000-8000-0000000000f2"; // event 1
    private static final String ORDER_3 = "00000000-0000-7000-8000-0000000000f3"; // event 2

    @BeforeAll
    static void migrate() {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate(); // fails if a script has errors or a checksum does not match

        dataSource =
                new DriverManagerDataSource(
                        POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
    }

    @BeforeEach
    void resetData() {
        // TRUNCATE does not fire the triggers that forbid DELETE.
        jdbc.execute(
                "TRUNCATE order_items, orders, event_seats, venue_seats, price_tiers, events, venues, users CASCADE");
        new ResourceDatabasePopulator(new ClassPathResource("db/test-fixtures.sql"))
                .execute(dataSource);
    }

    private void insertItem(
            String orderId, String eventId, String eventSeatId, String tierId, long price) {
        jdbc.update(
                """
                INSERT INTO order_items (order_id, event_id, event_seat_id, price_tier_id, price_paid, currency)
                VALUES (?::uuid, ?::uuid, ?::uuid, ?::uuid, ?, 'ARS')
                """,
                orderId,
                eventId,
                eventSeatId,
                tierId,
                price);
    }

    private int activeItems() {
        return jdbc.queryForObject(
                "SELECT count(*) FROM order_items WHERE released_at IS NULL", Integer.class);
    }

    @Test
    @DisplayName("generate_uuid_v7() generates valid version 7 UUIDs (and never fails)")
    void shouldGenerateValidUuidV7() {
        List<UUID> ids =
                jdbc.queryForList(
                        "SELECT generate_uuid_v7() FROM generate_series(1, 2000)", UUID.class);

        assertThat(ids).hasSize(2000).doesNotHaveDuplicates();
        assertThat(ids)
                .allSatisfy(
                        id -> {
                            assertThat(id.version()).isEqualTo(7);
                            assertThat(id.variant()).isEqualTo(2); // RFC 4122/9562 variant
                        });

        // and it works as the PK DEFAULT
        UUID venueId =
                jdbc.queryForObject(
                        """
                INSERT INTO venues (name, address, capacity) VALUES ('Quality Espacio', 'Cruz Roja 200', 4000)
                RETURNING id
                """,
                        UUID.class);
        assertThat(venueId.version()).isEqualTo(7);
    }

    @Test
    @DisplayName("The same physical seat can be sold for two different events")
    void sameVenueSeatCanBeSoldInDifferentEvents() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);
        insertItem(ORDER_3, EVENT_2, SEAT_1_EVENT_2, TIER_2, 12000);

        assertThat(activeItems()).isEqualTo(2);
    }

    @Test
    @DisplayName("A seat of an event cannot have two active items (anti-overselling)")
    void shouldPreventDoubleBooking() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);

        assertThatThrownBy(() -> insertItem(ORDER_2, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000))
                .isInstanceOf(DuplicateKeyException.class)
                .hasMessageContaining("ux_order_items_active_seat");
    }

    @Test
    @DisplayName("When an item is released, the seat can be sold again")
    void releasedSeatCanBeSoldAgain() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);
        jdbc.update(
                "UPDATE order_items SET released_at = now(), release_reason = 'EXPIRED' WHERE order_id = ?::uuid",
                ORDER_1);

        insertItem(ORDER_2, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);

        assertThat(activeItems()).isEqualTo(1);
    }

    @Test
    @DisplayName("An item cannot reference a seat from another event")
    void shouldRejectSeatFromAnotherEvent() {
        // SEAT_3_EVENT_2 belongs to event 2, but the order and the item declare event 1
        assertThatThrownBy(() -> insertItem(ORDER_1, EVENT_1, SEAT_3_EVENT_2, TIER_1, 10000))
                .isInstanceOf(DataIntegrityViolationException.class)
                .hasMessageContaining("fk_order_items_");
    }

    @Test
    @DisplayName("price_paid is immutable")
    void shouldPreventPricePaidUpdate() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);

        assertThatThrownBy(
                        () ->
                                jdbc.update(
                                        "UPDATE order_items SET price_paid = 100 WHERE order_id = ?::uuid",
                                        ORDER_1))
                .isInstanceOf(DataIntegrityViolationException.class)
                .hasMessageContaining("only released_at and release_reason can be modified");
    }

    @Test
    @DisplayName("A released item cannot be reactivated")
    void releasedItemCannotBeReactivated() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);
        jdbc.update(
                "UPDATE order_items SET released_at = now(), release_reason = 'CANCELLED' WHERE order_id = ?::uuid",
                ORDER_1);

        assertThatThrownBy(
                        () ->
                                jdbc.update(
                                        "UPDATE order_items SET released_at = NULL, "
                                                + "release_reason = NULL WHERE order_id = ?::uuid",
                                        ORDER_1))
                .isInstanceOf(DataIntegrityViolationException.class)
                .hasMessageContaining("cannot be modified or reactivated");
    }

    @Test
    @DisplayName("Orders and their items cannot be deleted")
    void shouldForbidDeletes() {
        insertItem(ORDER_1, EVENT_1, SEAT_1_EVENT_1, TIER_1, 10000);

        assertThatThrownBy(
                        () ->
                                jdbc.update(
                                        "DELETE FROM order_items WHERE order_id = ?::uuid",
                                        ORDER_1))
                .isInstanceOf(DataIntegrityViolationException.class)
                .hasMessageContaining("DELETE is not allowed on order_items");

        assertThatThrownBy(() -> jdbc.update("DELETE FROM orders WHERE id = ?::uuid", ORDER_3))
                .isInstanceOf(DataIntegrityViolationException.class)
                .hasMessageContaining("DELETE is not allowed on orders");
    }
}
