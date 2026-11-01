@file:JvmName("RateLimitStrategyKt")
package eu.kanade.tachiyomi.network.interceptor

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

@JvmOverloads
fun OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(null, permits, period, unit))

@JvmOverloads
fun OkHttpClient.Builder.rateLimitHost(
    host: HttpUrl,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): OkHttpClient.Builder = addInterceptor(SpecificHostRateLimitInterceptor(host, permits, period, unit))

@JvmOverloads
fun OkHttpClient.Builder.rateLimitHost(
    host: String,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): OkHttpClient.Builder {
    val httpUrl = host.toHttpUrlOrNull()
    return if (httpUrl != null) {
        rateLimitHost(httpUrl, permits, period, unit)
    } else {
        addInterceptor(RateLimitInterceptor(host, permits, period, unit))
    }
}

