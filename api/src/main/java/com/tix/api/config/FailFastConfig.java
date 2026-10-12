package com.tix.api.config;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "app.config")
public class FailFastConfig {
    @NotBlank(message = "Vital: The variable DB_URL is required to start the application")
    private String dbUrl;

    @NotBlank(message = "Vital: The variable REDIS_LOCKS_URL is required to start the application")
    private String redisLocksUrl;

    @NotBlank(message = "Vital: The JWT secret is required")
    @Size(min = 32, message = "Vital: The JWT secret must have at least 32 characters (256 bits)")
    private String jwtSecret;

    // Getters and setters
    public String getDbUrl() {
        return dbUrl;
    }

    public void setDbUrl(String dbUrl) {
        this.dbUrl = dbUrl;
    }

    public String getRedisLocksUrl() {
        return redisLocksUrl;
    }

    public void setRedisLocksUrl(String redisLocksUrl) {
        this.redisLocksUrl = redisLocksUrl;
    }

    public String getJwtSecret() {
        return jwtSecret;
    }

    public void setJwtSecret(String jwtSecret) {
        this.jwtSecret = jwtSecret;
    }
}
