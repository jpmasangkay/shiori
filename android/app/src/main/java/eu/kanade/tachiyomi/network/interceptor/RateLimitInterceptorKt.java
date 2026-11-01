package eu.kanade.tachiyomi.network.interceptor;

import java.util.concurrent.TimeUnit;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;

/**
 * Binary-compatibility shim for older Tachiyomi extensions (extensions-lib 1.2/1.3)
 * whose bytecode invokes RateLimitInterceptorKt.rateLimit / rateLimit$default,
 * while newer extensions (1.4/1.5) invoke RateLimitStrategyKt.rateLimit / rateLimit$default.
 */
public final class RateLimitInterceptorKt {
    private RateLimitInterceptorKt() {}

    public static OkHttpClient.Builder rateLimit(OkHttpClient.Builder builder, int permits) {
        return rateLimit(builder, permits, 1L, TimeUnit.SECONDS);
    }

    public static OkHttpClient.Builder rateLimit(OkHttpClient.Builder builder, int permits, long period) {
        return rateLimit(builder, permits, period, TimeUnit.SECONDS);
    }

    public static OkHttpClient.Builder rateLimit(
            OkHttpClient.Builder builder, int permits, long period, TimeUnit unit) {
        return RateLimitStrategyKt.rateLimit(builder, permits, period, unit);
    }

    public static OkHttpClient.Builder rateLimit$default(
            OkHttpClient.Builder builder, int permits, long period, TimeUnit unit, int mask, Object marker) {
        if ((mask & 2) != 0) period = 1L;
        if ((mask & 4) != 0) unit = TimeUnit.SECONDS;
        return rateLimit(builder, permits, period, unit);
    }

    public static OkHttpClient.Builder rateLimitHost(
            OkHttpClient.Builder builder, HttpUrl host, int permits) {
        return rateLimitHost(builder, host, permits, 1L, TimeUnit.SECONDS);
    }

    public static OkHttpClient.Builder rateLimitHost(
            OkHttpClient.Builder builder, HttpUrl host, int permits, long period) {
        return rateLimitHost(builder, host, permits, period, TimeUnit.SECONDS);
    }

    public static OkHttpClient.Builder rateLimitHost(
            OkHttpClient.Builder builder, HttpUrl host, int permits, long period, TimeUnit unit) {
        return RateLimitStrategyKt.rateLimitHost(builder, host, permits, period, unit);
    }

    public static OkHttpClient.Builder rateLimitHost$default(
            OkHttpClient.Builder builder, HttpUrl host, int permits, long period, TimeUnit unit, int mask, Object marker) {
        if ((mask & 4) != 0) period = 1L;
        if ((mask & 8) != 0) unit = TimeUnit.SECONDS;
        return rateLimitHost(builder, host, permits, period, unit);
    }

    public static OkHttpClient.Builder rateLimitHost(
            OkHttpClient.Builder builder, String host, int permits, long period, TimeUnit unit) {
        return RateLimitStrategyKt.rateLimitHost(builder, host, permits, period, unit);
    }

    public static OkHttpClient.Builder rateLimitHost$default(
            OkHttpClient.Builder builder, String host, int permits, long period, TimeUnit unit, int mask, Object marker) {
        if ((mask & 4) != 0) period = 1L;
        if ((mask & 8) != 0) unit = TimeUnit.SECONDS;
        return rateLimitHost(builder, host, permits, period, unit);
    }
}

