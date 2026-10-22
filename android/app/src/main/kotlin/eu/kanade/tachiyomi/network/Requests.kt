@file:JvmName("RequestsKt")
package eu.kanade.tachiyomi.network

import okhttp3.CacheControl
import okhttp3.Headers
import okhttp3.Request
import okhttp3.RequestBody

fun GET(
    url: String,
    headers: Headers = Headers.Builder().build(),
    cache: CacheControl = CacheControl.FORCE_NETWORK
): Request {
    return Request.Builder()
        .url(url)
        .headers(headers)
        .cacheControl(cache)
        .build()
}

fun POST(
    url: String,
    headers: Headers = Headers.Builder().build(),
    body: RequestBody = RequestBody.create(null, ByteArray(0)),
    cache: CacheControl = CacheControl.FORCE_NETWORK
): Request {
    return Request.Builder()
        .url(url)
        .post(body)
        .headers(headers)
        .cacheControl(cache)
        .build()
}
