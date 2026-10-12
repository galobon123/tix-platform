package com.tix.api.config;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.context.ConfigurationPropertiesAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.boot.validation.autoconfigure.ValidationAutoConfiguration;

public class FailFastConfigTest {
    private final ApplicationContextRunner runner =
            new ApplicationContextRunner()
                    .withConfiguration(
                            AutoConfigurations.of(
                                    ConfigurationPropertiesAutoConfiguration.class,
                                    ValidationAutoConfiguration.class))
                    .withUserConfiguration(FailFastConfig.class);

    private static final String REDIS = "redis://localhost:6379";
    private static final String JWT = "test-secret-0123456789012345678901234567890";

    @Test
    void withoutDbUrl() {
        runner.withPropertyValues(
                        "app.config.redis-locks-url=" + REDIS, "app.config.jwt-secret=" + JWT)
                .run(ctx -> assertThat(ctx).hasFailed());
    }

    @Test
    void jwtToShort() {
        runner.withPropertyValues(
                        "app.config.db-url=jdbc:postgresql://localhost:5432/tickets",
                        "app.config.redis-locks-url=" + REDIS,
                        "app.config.jwt-secret=short")
                .run(ctx -> assertThat(ctx).hasFailed());
    }

    @Test
    void startWithCompleteConfiguration() {
        runner.withPropertyValues(
                        "app.config.db-url=jdbc:postgresql://localhost:5432/tickets",
                        "app.config.redis-locks-url=" + REDIS,
                        "app.config.jwt-secret=" + JWT)
                .run(ctx -> assertThat(ctx).hasNotFailed());
    }
}
