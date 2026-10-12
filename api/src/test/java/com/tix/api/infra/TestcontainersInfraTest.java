package com.tix.api.infra;

import static org.assertj.core.api.Assertions.assertThat;

import com.redis.testcontainers.RedisContainer;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.util.Map;
import java.util.Set;
import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
// The .containers.KafkaContainer package is the old one: it expects confluentinc/cp-kafka and
// rejects apache/kafka with "Failed to verify that image ... is a compatible substitute".
// The one under .kafka is the one that speaks native KRaft and uses apache/kafka directly.
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * HU 01.3, task 2: the integration suite must run against REAL PostgreSQL, Redis and Kafka via
 * Testcontainers, not against H2 or an embedded broker.
 *
 * <p>This test does not test business logic: it tests that the project's test infrastructure works.
 * Without it, the gate would be unverified configuration, which is exactly what the HU asks to
 * avoid.
 *
 * <p>It deliberately uses the same images as the HU 01.1 stack, so a local run downloads nothing
 * extra:
 *
 * <ul>
 *   <li>Testcontainers 2.x renamed the modules: {@code
 *       org.testcontainers.postgresql.PostgreSQLContainer} and {@code
 *       org.testcontainers.kafka.KafkaContainer} are no longer in {@code
 *       org.testcontainers.containers}. Redis is the exception: its groupId is {@code com.redis}.
 *   <li>Redis is verified by speaking raw RESP over a socket (PING -> PONG) instead of adding
 *       another client to the classpath. The check is smaller and does not depend on the driver
 *       version.
 * </ul>
 *
 * <p>{@code disabledWithoutDocker} makes the class skip itself when Docker is unavailable, instead
 * of breaking the build. It is the difference between "CI cannot run" and "CI did not run this".
 */
@Testcontainers(disabledWithoutDocker = true)
@DisplayName("HU 01.3 T2 - Testcontainers starts real PostgreSQL, Redis and Kafka")
class TestcontainersInfraTest {

    @Container
    static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer(DockerImageName.parse("postgres:17"))
                    .withDatabaseName("tickets_test")
                    .withUsername("test")
                    .withPassword("test")
                    .withStartupTimeout(Duration.ofMinutes(2));

    @Container
    static final RedisContainer REDIS =
            new RedisContainer(DockerImageName.parse("redis:7"))
                    .withStartupTimeout(Duration.ofMinutes(2));

    @Container
    static final KafkaContainer KAFKA =
            new KafkaContainer(DockerImageName.parse("apache/kafka:4.2.2"))
                    .withStartupTimeout(Duration.ofMinutes(2));

    @Test
    @DisplayName("PostgreSQL: a real query responds over JDBC")
    void postgresRespondsToARealQuery() throws Exception {
        String url = POSTGRES.getJdbcUrl();
        String user = POSTGRES.getUsername();
        String password = POSTGRES.getPassword();

        try (Connection con = DriverManager.getConnection(url, user, password);
                Statement st = con.createStatement();
                ResultSet rs = st.executeQuery("select 1 as value, current_database() as db")) {

            assertThat(rs.next()).isTrue();
            assertThat(rs.getInt("value")).isEqualTo(1);
            assertThat(rs.getString("db")).isEqualTo("tickets_test");
        }
    }

    @Test
    @DisplayName("Redis: PING responds PONG over raw RESP")
    void redisRespondsToPing() throws Exception {
        try (Socket socket = new Socket(REDIS.getRedisHost(), REDIS.getRedisPort())) {
            OutputStream out = socket.getOutputStream();
            out.write("PING\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();

            String response = readLine(socket.getInputStream());

            assertThat(response).isEqualTo("+PONG");
        }
    }

    @Test
    @DisplayName("Kafka: the broker responds to an AdminClient.listTopics")
    void kafkaRespondsToListTopics() throws Exception {
        Map<String, Object> config =
                Map.of(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, KAFKA.getBootstrapServers());

        try (Admin admin = Admin.create(config)) {
            Set<String> topics = admin.listTopics().names().get();

            // It does not assert that this is empty: 07.1+ will create topics. It asserts that the
            // broker responded, which is what proves the container came up operational.
            assertThat(topics).isNotNull();
        }
    }

    /** Reads a CRLF-terminated line from a socket stream. The RESP protocol uses CRLF. */
    private static String readLine(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\r') {
                in.read();
                break;
            }
            sb.append((char) c);
        }
        return sb.toString();
    }
}
