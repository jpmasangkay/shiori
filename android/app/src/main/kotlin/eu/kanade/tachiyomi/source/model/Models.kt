package eu.kanade.tachiyomi.source.model

import android.net.Uri
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.io.Serializable

interface SManga : Serializable {
    var url: String
    var title: String
    var artist: String?
    var author: String?
    var description: String?
    var genre: String?
    var status: Int
    var thumbnail_url: String?
    var update_strategy: UpdateStrategy
    var initialized: Boolean
    var memo: JsonObject?

    fun copyFrom(other: SManga) {
        if (other.title.isNotBlank()) title = other.title
        if (other.author != null) author = other.author
        if (other.artist != null) artist = other.artist
        if (other.description != null) description = other.description
        if (other.genre != null) genre = other.genre
        if (other.thumbnail_url != null) thumbnail_url = other.thumbnail_url
        status = other.status
        update_strategy = other.update_strategy
        if (!initialized) initialized = other.initialized
        if (other.memo != null) memo = other.memo
    }

    fun getGenres(): List<String>? {
        if (genre.isNullOrBlank()) return null
        return genre?.split(", ")?.map { it.trim() }?.filterNot { it.isEmpty() }
    }

    companion object {
        const val UNKNOWN = 0
        const val ONGOING = 1
        const val COMPLETED = 2
        const val LICENSED = 3
        const val PUBLISHING_FINISHED = 4
        const val CANCELLED = 5
        const val ON_HIATUS = 6

        fun create(): SManga = SMangaImpl()
    }
}

enum class UpdateStrategy {
    ALWAYS_UPDATE,
    ONLY_FETCH_ONCE
}

class SMangaImpl : SManga {
    override var url: String = ""
    override var title: String = ""
    override var artist: String? = null
    override var author: String? = null
    override var description: String? = null
    override var genre: String? = null
    override var status: Int = SManga.UNKNOWN
    override var thumbnail_url: String? = null
    override var update_strategy: UpdateStrategy = UpdateStrategy.ALWAYS_UPDATE
    override var initialized: Boolean = false

    private var _memo: JsonObject? = null
    override var memo: JsonObject?
        get() = _memo ?: generateDefaultMemo()
        set(value) { _memo = value }

    private fun generateDefaultMemo(): JsonObject {
        val slug = url.trim('/').substringAfterLast('/')
        return buildJsonObject {
            if (slug.isNotEmpty()) {
                put("slug", JsonPrimitive(slug))
                put("mangaSlug", JsonPrimitive(slug))
                put("seriesSlug", JsonPrimitive(slug))
            }
        }
    }
}

interface SChapter : Serializable {
    var url: String
    var name: String
    var date_upload: Long
    var chapter_number: Float
    var scanlator: String?
    var memo: JsonObject?

    fun copyFrom(other: SChapter) {
        name = other.name
        url = other.url
        date_upload = other.date_upload
        chapter_number = other.chapter_number
        scanlator = other.scanlator
        if (other.memo != null) memo = other.memo
    }

    companion object {
        fun create(): SChapter = SChapterImpl()
    }
}

class SChapterImpl : SChapter {
    override var url: String = ""
    override var name: String = ""
    override var date_upload: Long = 0L
    override var chapter_number: Float = -1f
    override var scanlator: String? = null

    private var _memo: JsonObject? = null
    override var memo: JsonObject?
        get() = _memo ?: generateDefaultMemo()
        set(value) { _memo = value }

    private fun generateDefaultMemo(): JsonObject {
        val parts = url.trim('/').split('/')
        val mangaSlug = if (parts.size >= 2) parts[parts.size - 2] else ""
        val chapterSlug = if (parts.isNotEmpty()) parts.last() else ""
        return buildJsonObject {
            if (mangaSlug.isNotEmpty()) {
                put("mangaSlug", JsonPrimitive(mangaSlug))
                put("slug", JsonPrimitive(mangaSlug))
            }
            if (chapterSlug.isNotEmpty()) {
                put("chapterSlug", JsonPrimitive(chapterSlug))
            }
        }
    }
}

open class Page @JvmOverloads constructor(
    val index: Int,
    val url: String = "",
    var imageUrl: String? = null,
    val uri: Uri? = null
) {
    val number: Int get() = index + 1
    var text: String? = null
    var status: Int = READY
    var progress: Int = 0

    companion object {
        const val READY = 0
        const val QUEUE = 1
        const val LOAD_PAGE = 2
        const val DOWNLOAD_IMAGE = 3
        const val READY_TO_SHOW = 4
        const val ERROR = 5
    }
}

data class MangasPage(val mangas: List<SManga>, val hasNextPage: Boolean)

open class Filter<T>(val name: String, var state: T) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Filter<*>) return false

        return name == other.name && state == other.state
    }

    override fun hashCode(): Int {
        var result = name.hashCode()
        result = 31 * result + (state?.hashCode() ?: 0)
        return result
    }

    open class Header(name: String) : Filter<Any>(name, 0)
    open class Separator @JvmOverloads constructor(name: String = "") : Filter<Any>(name, 0)
    open class HelpDialog(name: String, val dialogTitle: String, val message: String) : Filter<Any>(name, 0)
    abstract class Select<V> @JvmOverloads constructor(name: String, val values: Array<out V>, state: Int = 0) : Filter<Int>(name, state)
    abstract class Text @JvmOverloads constructor(name: String, state: String = "") : Filter<String>(name, state)
    abstract class CheckBox @JvmOverloads constructor(name: String, state: Boolean = false) : Filter<Boolean>(name, state)
    abstract class TriState @JvmOverloads constructor(name: String, state: Int = STATE_IGNORE) : Filter<Int>(name, state) {
        fun isIgnored(): Boolean = state == STATE_IGNORE
        fun isIncluded(): Boolean = state == STATE_INCLUDE
        fun isExcluded(): Boolean = state == STATE_EXCLUDE

        companion object {
            const val STATE_IGNORE = 0
            const val STATE_INCLUDE = 1
            const val STATE_EXCLUDE = 2
        }
    }
    abstract class Group<V>(name: String, state: List<V>) : Filter<List<V>>(name, state)
    abstract class Sort @JvmOverloads constructor(name: String, val values: Array<String>, state: Selection? = null) :
        Filter<Sort.Selection?>(name, state) {
        data class Selection(val index: Int, val ascending: Boolean)
    }
}

class FilterList @JvmOverloads constructor(val list: List<Filter<*>> = emptyList()) : List<Filter<*>> by list {
    constructor(vararg filters: Filter<*>) : this(filters.toList())

    override fun equals(other: Any?): Boolean {
        return other is FilterList && list == other.list
    }

    override fun hashCode(): Int {
        return list.hashCode()
    }
}
