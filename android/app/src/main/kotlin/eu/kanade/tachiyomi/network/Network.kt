package eu.kanade.tachiyomi.network

import android.content.Context
import okhttp3.Cache
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import java.io.File
import java.net.InetAddress
import java.util.concurrent.TimeUnit

class HttpException(val code: Int) : IllegalStateException("HTTP error $code")

open class NetworkHelper(val context: Context) {
    companion object {
        private const val PREF_NAME = "shiori_network_prefs"
        private const val KEY_DOH_PROVIDER = "doh_provider"
        private const val HTTP_CACHE_SIZE_BYTES = 10L * 1024L * 1024L // 10 MB

        @Volatile
        private var currentDohProvider: String = "none"

        fun getDohProvider(context: Context): String {
            return try {
                val saved = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                    .getString(KEY_DOH_PROVIDER, "none") ?: "none"
                currentDohProvider = saved
                saved
            } catch (_: Throwable) {
                currentDohProvider
            }
        }

        fun setDohProvider(context: Context, provider: String) {
            val normalized = when (provider.lowercase()) {
                "cloudflare", "google", "quad9", "adguard" -> provider.lowercase()
                else -> "none"
            }
            currentDohProvider = normalized
            try {
                context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(KEY_DOH_PROVIDER, normalized)
                    .apply()
            } catch (_: Throwable) {}
        }
    }

    open val cookieJar: AndroidCookieJar by lazy { AndroidCookieJar() }

    open val cookieManager: AndroidCookieJar
        get() = cookieJar

    private val httpCache: Cache? by lazy {
        try {
            val cacheDir = File(context.cacheDir, "network_cache")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            Cache(cacheDir, HTTP_CACHE_SIZE_BYTES)
        } catch (_: Throwable) {
            null
        }
    }

    private val bootstrapClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    private val dynamicDns: Dns = object : Dns {
        @Volatile
        private var cachedProvider: String = "none"
        @Volatile
        private var cachedDoh: Dns? = null

        private fun resolveDoh(provider: String): Dns? {
            if (provider == "none") return null
            if (cachedProvider == provider && cachedDoh != null) return cachedDoh
            val built: Dns? = try {
                when (provider) {
                    "cloudflare" -> DnsOverHttps.Builder()
                        .client(bootstrapClient)
                        .url("https://cloudflare-dns.com/dns-query".toHttpUrl())
                        .bootstrapDnsHosts(
                            InetAddress.getByName("1.1.1.1"),
                            InetAddress.getByName("1.0.0.1"),
                        )
                        .build()
                    "google" -> DnsOverHttps.Builder()
                        .client(bootstrapClient)
                        .url("https://dns.google/dns-query".toHttpUrl())
                        .bootstrapDnsHosts(
                            InetAddress.getByName("8.8.8.8"),
                            InetAddress.getByName("8.8.4.4"),
                        )
                        .build()
                    "quad9" -> DnsOverHttps.Builder()
                        .client(bootstrapClient)
                        .url("https://dns.quad9.net/dns-query".toHttpUrl())
                        .bootstrapDnsHosts(
                            InetAddress.getByName("9.9.9.9"),
                            InetAddress.getByName("149.112.112.112"),
                        )
                        .build()
                    "adguard" -> DnsOverHttps.Builder()
                        .client(bootstrapClient)
                        .url("https://dns.adguard-dns.com/dns-query".toHttpUrl())
                        .bootstrapDnsHosts(
                            InetAddress.getByName("94.140.14.14"),
                            InetAddress.getByName("94.140.15.15"),
                        )
                        .build()
                    else -> null
                }
            } catch (_: Throwable) {
                null
            }
            cachedProvider = provider
            cachedDoh = built
            return built
        }

        override fun lookup(hostname: String): List<InetAddress> {
            val doh = resolveDoh(currentDohProvider)
            if (doh != null) {
                try {
                    return doh.lookup(hostname)
                } catch (_: Throwable) {
                    // Fallback gracefully to system DNS if DoH endpoint is unreachable
                }
            }
            return Dns.SYSTEM.lookup(hostname)
        }
    }

    init {
        getDohProvider(context)
    }

    open val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .cookieJar(cookieJar)
            .dns(dynamicDns)
            .apply { httpCache?.let { cache(it) } }
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor())
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor(defaultUserAgentProvider()))
            .addInterceptor(eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor(context))
            .build()
    }

    open val cloudflareClient: OkHttpClient
        get() = client

    open val defaultClient: OkHttpClient
        get() = client

    open fun defaultUserAgentProvider(): String {
        return try {
            android.webkit.WebSettings.getDefaultUserAgent(context)
        } catch (_: Throwable) {
            "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36"
        }
    }
}

typealias UncaughtExceptionInterceptor = eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
typealias CloudflareInterceptor = eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
typealias UserAgentInterceptor = eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
typealias RateLimitInterceptor = eu.kanade.tachiyomi.network.interceptor.RateLimitInterceptor
