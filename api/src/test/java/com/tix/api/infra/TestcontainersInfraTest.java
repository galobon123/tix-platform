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
// El paquete .containers.KafkaContainer es el viejo: espera confluentinc/cp-kafka y
// rechaza apache/kafka con "Failed to verify that image ... is a compatible substitute".
// El de .kafka es el que habla KRaft nativo y usa apache/kafka directamente.
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * HU 01.3, tarea 2: la suite de integracion tiene que correr contra PostgreSQL, Redis y Kafka
 * REALES via Testcontainers, no contra H2 ni un broker embebido.
 *
 * <p>Este test no prueba negocio: prueba que la infraestructura de test del proyecto funciona. Sin
 * el, el gate quedaria como configuracion no verificada, que es exactamente lo que la HU pide
 * evitar.
 *
 * <p>Usa las mismas imagenes que el stack de HU 01.1 a proposito, para que un run local no
 * descargue nada extra:
 *
 * <ul>
 *   <li>Testcontainers 2.x cambio los nombres de los modulos: {@code
 *       org.testcontainers.postgresql.PostgreSQLContainer} y {@code
 *       org.testcontainers.kafka.KafkaContainer} ya no estan en {@code
 *       org.testcontainers.containers}. Redis es la excepcion: su groupId es {@code com.redis}.
 *   <li>Redis se verifica speaking RESP crudo por socket (PING -> PONG) en vez de agregar un
 *       cliente mas al classpath. La prueba es mas chica y no depende de la version del driver.
 * </ul>
 *
 * <p>{@code disabledWithoutDocker} hace que la clase se saltee sola si no hay Docker, en vez de
 * romper el build. Es la diferencia entre "el CI no puede correr" y "el CI no corrio esto".
 */
@Testcontainers(disabledWithoutDocker = true)
@DisplayName("HU 01.3 T2 - Testcontainers levanta PostgreSQL, Redis y Kafka reales")
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
    @DisplayName("PostgreSQL: una consulta real responde por JDBC")
    void postgresRespondeUnaConsultaReal() throws Exception {
        String url = POSTGRES.getJdbcUrl();
        String user = POSTGRES.getUsername();
        String password = POSTGRES.getPassword();

        try (Connection con = DriverManager.getConnection(url, user, password);
                Statement st = con.createStatement();
                ResultSet rs = st.executeQuery("select 1 as valor, current_database() as db")) {

            assertThat(rs.next()).isTrue();
            assertThat(rs.getInt("valor")).isEqualTo(1);
            assertThat(rs.getString("db")).isEqualTo("tickets_test");
        }
    }

    @Test
    @DisplayName("Redis: PING responde PONG por RESP crudo")
    void redisRespondePing() throws Exception {
        try (Socket socket = new Socket(REDIS.getRedisHost(), REDIS.getRedisPort())) {
            OutputStream out = socket.getOutputStream();
            out.write("PING\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();

            String respuesta = leerLinea(socket.getInputStream());

            assertThat(respuesta).isEqualTo("+PONG");
        }
    }

    @Test
    @DisplayName("Kafka: el broker responde un AdminClient.listTopics")
    void kafkaRespondeListTopics() throws Exception {
        Map<String, Object> config =
                Map.of(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, KAFKA.getBootstrapServers());

        try (Admin admin = Admin.create(config)) {
            Set<String> topics = admin.listTopics().names().get();

            // No se afirma que este vacio: 07.1+ van a crear topics. Se afirma que el broker
            // respondio, que es lo que prueba que el container quedo operativo.
            assertThat(topics).isNotNull();
        }
    }

    /** Lee una linea CRLF-terminada de un stream de sockets. El protocolo RESP usa CRLF. */
    private static String leerLinea(InputStream in) throws IOException {
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
