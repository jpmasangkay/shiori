package eu.kanade.tachiyomi.network

import android.content.Context
import okhttp3.CacheControl
import okhttp3.Call
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import rx.Observable
import java.io.IOException
import java.util.concurrent.TimeUnit



class HttpException(val code: Int) : IllegalStateException("HTTP error $code")

open class NetworkHelper(val context: Context) {
    open val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor())
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor())
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor(context))
            .addInterceptor(okhttp3.CompressionInterceptor())
            .addInterceptor(okhttp3.brotli.BrotliInterceptor)
            .build()
    }

    open val cloudflareClient: OkHttpClient
        get() = client

    open val defaultClient: OkHttpClient
        get() = client

    open val cookieJar: okhttp3.CookieJar
        get() = client.cookieJar

    open fun defaultUserAgentProvider(): String =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
}

typealias UncaughtExceptionInterceptor = eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
typealias CloudflareInterceptor = eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
typealias UserAgentInterceptor = eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor

open class RateLimitInterceptor(
    val permits: Int,
    val period: Long = 1,
    val unit: TimeUnit = TimeUnit.SECONDS
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return chain.proceed(chain.request())
    }
}

fun OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))

fun OkHttpClient.Builder.rateLimitHost(
    url: okhttp3.HttpUrl,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))
