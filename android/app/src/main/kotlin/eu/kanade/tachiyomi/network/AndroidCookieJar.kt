package eu.kanade.tachiyomi.network

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

class AndroidCookieJar : CookieJar {
    private val manager: CookieManager by lazy {
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
        }
    }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val urlString = url.toString()
        for (cookie in cookies) {
            try {
                manager.setCookie(urlString, cookie.toString())
            } catch (_: Throwable) {}
        }
        try {
            manager.flush()
        } catch (_: Throwable) {}
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val rawCookies = try {
            manager.getCookie(url.toString())
        } catch (_: Throwable) {
            null
        } ?: return emptyList()

        return rawCookies.split(";").mapNotNull {
            try {
                Cookie.parse(url, it.trim())
            } catch (_: Throwable) {
                null
            }
        }
    }
}
