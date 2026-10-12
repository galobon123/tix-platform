package com.tix.api;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

@SpringBootTest(
        properties = {
            "app.config.db-url=jdbc:postgresql://localhost:5432/tickets",
            "app.config.redis-locks-url=redis://localhost:6379",
            "app.config.jwt-secret=test-secret-test-secret-test-secret"
        })
class ApiApplicationTests {

    @Test
    void contextLoads() {}
}
