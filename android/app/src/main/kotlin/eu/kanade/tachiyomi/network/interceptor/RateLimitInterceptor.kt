package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response
import java.util.concurrent.TimeUnit

open class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return try {
            chain.proceed(chain.request())
        } catch (e: Throwable) {
            if (e is java.io.IOException) throw e
            throw java.io.IOException(e.message, e)
        }
    }
}

open class CloudflareInterceptor(val context: android.content.Context? = null) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return chain.proceed(chain.request())
    }
}

open class UserAgentInterceptor(
    val defaultUserAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val reqBuilder = original.newBuilder()
        if (original.header("User-Agent") == null) {
            reqBuilder.header("User-Agent", defaultUserAgent)
        }
        return chain.proceed(reqBuilder.build())
    }
}

open class RateLimitInterceptor(
    val permits: Int,
    val period: Long = 1,
    val unit: TimeUnit = TimeUnit.SECONDS
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return chain.proceed(chain.request())
    }
}

fun okhttp3.OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): okhttp3.OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))

fun okhttp3.OkHttpClient.Builder.rateLimitHost(
    url: okhttp3.HttpUrl,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): okhttp3.OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))
