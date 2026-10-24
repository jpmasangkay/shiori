package eu.kanade.tachiyomi.network.interceptor

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
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
        val response = chain.proceed(chain.request())
        if (response.code == 403 || response.code == 503) {
            val server = response.header("Server") ?: ""
            val cfMitigated = response.header("Cf-Mitigated") ?: ""
            if (server.contains("cloudflare", ignoreCase = true) || cfMitigated.isNotEmpty()) {
                android.util.Log.w("CloudflareInterceptor", "Cloudflare challenge detected on ${chain.request().url} (HTTP ${response.code})")
                try {
                    android.webkit.CookieManager.getInstance().flush()
                } catch (_: Throwable) {}
            }
        }
        return response
    }
}

open class UserAgentInterceptor(
    val defaultUserAgent: String = "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36"
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val currentUa = original.header("User-Agent")
        val reqBuilder = original.newBuilder()

        if (currentUa.isNullOrBlank() || currentUa.contains("okhttp", ignoreCase = true)) {
            reqBuilder.header("User-Agent", defaultUserAgent)
        }
        if (original.header("Referer").isNullOrBlank()) {
            reqBuilder.header("Referer", "${original.url.scheme}://${original.url.host}/")
        }
        if (original.header("Accept-Language").isNullOrBlank()) {
            reqBuilder.header("Accept-Language", "en-US,en;q=0.9")
        }
        if (original.header("sec-ch-ua-mobile").isNullOrBlank()) {
            reqBuilder.header("sec-ch-ua-mobile", "?1")
        }
        if (original.header("sec-ch-ua-platform").isNullOrBlank()) {
            reqBuilder.header("sec-ch-ua-platform", "\"Android\"")
        }

        return chain.proceed(reqBuilder.build())
    }
}

open class RateLimitInterceptor @JvmOverloads constructor(
    val permits: Int,
    val period: Long = 1,
    val unit: TimeUnit = TimeUnit.SECONDS
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return chain.proceed(chain.request())
    }
}

@JvmOverloads
fun okhttp3.OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): okhttp3.OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))

@JvmOverloads
fun okhttp3.OkHttpClient.Builder.rateLimitHost(
    url: okhttp3.HttpUrl,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): okhttp3.OkHttpClient.Builder = addInterceptor(RateLimitInterceptor(permits, period, unit))

@JvmOverloads
fun okhttp3.OkHttpClient.Builder.rateLimitHost(
    url: String,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
): okhttp3.OkHttpClient.Builder {
    val httpUrl = url.toHttpUrlOrNull()
    return if (httpUrl != null) {
        rateLimitHost(httpUrl, permits, period, unit)
    } else {
        rateLimit(permits, period, unit)
    }
}
