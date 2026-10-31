@file:JvmName("JsoupExtensionsKt")
package eu.kanade.tachiyomi.util

import okhttp3.Response
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

@JvmOverloads
fun Response.asJsoup(html: String? = null): Document {
    val content = html ?: try { body?.string().orEmpty() } catch (_: Throwable) { "" }
    return Jsoup.parse(content, request.url.toString())
}

@JvmOverloads
fun Response.asJsoupDocument(html: String? = null): Document {
    return asJsoup(html)
}

fun Element.attrOrNull(attributeKey: String): String? {
    return attr(attributeKey).takeUnless { it.isBlank() }?.trim()
}

fun Element.selectLast(cssQuery: String): Element? = select(cssQuery).lastOrNull()

fun Element.textOrNull(): String? = text().takeUnless { it.isEmpty() }

fun org.jsoup.select.Elements.textOrNull(): String? = text().takeUnless { it.isEmpty() }

fun Element.ownTextOrNull(): String? = ownText().takeUnless { it.isEmpty() }

fun String.asJsoup(baseUrl: String): Document = Jsoup.parse(this, baseUrl)

