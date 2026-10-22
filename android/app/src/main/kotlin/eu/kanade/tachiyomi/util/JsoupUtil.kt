@file:JvmName("JsoupExtensionsKt")
package eu.kanade.tachiyomi.util

import okhttp3.Response
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

fun Response.asJsoup(html: String? = null): Document {
    val content = html ?: try { body?.string().orEmpty() } catch (_: Throwable) { "" }
    return Jsoup.parse(content, request.url.toString())
}

fun Response.asJsoupDocument(html: String? = null): Document {
    return asJsoup(html)
}

fun Element.attrOrNull(attributeKey: String): String? {
    return if (hasAttr(attributeKey)) attr(attributeKey) else null
}
