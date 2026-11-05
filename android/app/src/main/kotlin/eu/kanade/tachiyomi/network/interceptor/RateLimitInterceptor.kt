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
        val request = chain.request()
        val originalHost = request.url.host
        val response = chain.proceed(request)
        if (response.code == 403 || response.code == 503) {
            val server = response.header("Server") ?: ""
            val cfMitigated = response.header("Cf-Mitigated") ?: ""
            if (server.contains("cloudflare", ignoreCase = true) || cfMitigated.isNotEmpty()) {
                android.util.Log.w("CloudflareInterceptor", "Cloudflare challenge detected on ${request.url} (HTTP ${response.code})")
                try {
                    android.webkit.CookieManager.getInstance().flush()
                } catch (_: Throwable) {}
            }

            // Transparent failover for blocked Comick mirror (comick.live -> comick.art)
            if (originalHost.equals("comick.live", ignoreCase = true) || originalHost.equals("www.comick.live", ignoreCase = true)) {
                response.close()
                val newUrl = request.url.newBuilder()
                    .host("comick.art")
                    .build()
                val newRequest = request.newBuilder()
                    .url(newUrl)
                    .header("Referer", "https://comick.art/")
                    .build()
                android.util.Log.i("CloudflareInterceptor", "Transparently rewriting blocked Comick request from $originalHost to ${newUrl.host}")
                return chain.proceed(newRequest)
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
    private val host: String?,
    val permits: Int,
    val period: Long = 1,
    val unit: TimeUnit = TimeUnit.SECONDS
) : Interceptor {

    @JvmOverloads
    constructor(
        permits: Int,
        period: Long = 1,
        unit: TimeUnit = TimeUnit.SECONDS
    ) : this(null, permits, period, unit)

    private val requestQueue = ArrayDeque<Long>(permits.coerceAtLeast(1))
    private val rateLimitMillis = unit.toMillis(period).coerceAtLeast(1L)

    override fun intercept(chain: Interceptor.Chain): Response {
        val req = chain.request()
        if (host != null && !req.url.host.equals(host, ignoreCase = true)) {
            return chain.proceed(req)
        }
        if (permits > 0) {
            var sleepMs = 0L
            synchronized(requestQueue) {
                val now = android.os.SystemClock.elapsedRealtime()
                while (requestQueue.isNotEmpty() && now - requestQueue.first() >= rateLimitMillis) {
                    requestQueue.removeFirst()
                }
                if (requestQueue.size >= permits) {
                    val oldest = requestQueue.removeFirst()
                    val waitTime = rateLimitMillis - (now - oldest)
                    if (waitTime > 0L) {
                        sleepMs = waitTime
                        requestQueue.addLast(now + waitTime)
                    } else {
                        requestQueue.addLast(now)
                    }
                } else {
                    requestQueue.addLast(now)
                }
            }
            if (sleepMs > 0L) {
                try {
                    Thread.sleep(sleepMs.coerceAtMost(5000L))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
        return chain.proceed(req)
    }
}

open class SpecificHostRateLimitInterceptor @JvmOverloads constructor(
    val httpUrl: okhttp3.HttpUrl,
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS
) : RateLimitInterceptor(httpUrl.host, permits, period, unit)
