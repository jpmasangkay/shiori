package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.SMangaUpdateImpl
import eu.kanade.tachiyomi.util.asJsoup
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import rx.Observable
import java.security.MessageDigest
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

abstract class HttpSource : CatalogueSource {
    abstract val baseUrl: String
    override val lang: String get() = ""
    override val supportsLatest: Boolean get() = false

    override val id: Long by lazy {
        val key = "${name.lowercase()}/$lang/$versionId"
        val bytes = MessageDigest.getInstance("MD5").digest(key.toByteArray())
        (0..7).map { bytes[it].toLong() and 0xff shl 8 * (7 - it) }.reduce(Long::or) and Long.MAX_VALUE
    }

    open val versionId: Int = 1

    open val preferences: android.content.SharedPreferences by lazy {
        try {
            val app = Injekt.get<android.app.Application>()
            app.getSharedPreferences("source_$id", android.content.Context.MODE_PRIVATE)
        } catch (_: Exception) {
            try {
                Injekt.get<android.content.SharedPreferences>()
            } catch (_: Exception) {
                android.preference.PreferenceManager.getDefaultSharedPreferences(
                    Injekt.get<android.content.Context>()
                )
            }
        }
    }

    open fun headersBuilder(): Headers.Builder = Headers.Builder()

    open val network: eu.kanade.tachiyomi.network.NetworkHelper
        get() = Injekt.get<eu.kanade.tachiyomi.network.NetworkHelper>()

    open val client: OkHttpClient
        get() = try { network.client } catch (_: Throwable) { OkHttpClient.Builder().build() }

    open val headers: Headers by lazy { headersBuilder().build() }

    open fun getMangaUrl(manga: SManga): String = baseUrl + manga.url
    open fun getChapterUrl(chapter: SChapter): String = baseUrl + chapter.url

    // Popular
    open fun popularMangaRequest(page: Int): Request = GET(baseUrl, headers)
    open fun popularMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getPopularManga(page: Int): MangasPage {
        val response = client.newCall(popularMangaRequest(page)).awaitSuccess()
        return popularMangaParse(response)
    }

    override fun fetchPopularManga(page: Int): Observable<MangasPage> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getPopularManga(page) }
        }
    }

    // Search
    open fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = GET(baseUrl, headers)
    open fun searchMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val response = client.newCall(searchMangaRequest(page, query, filters)).awaitSuccess()
        return searchMangaParse(response)
    }

    override fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getSearchManga(page, query, filters) }
        }
    }

    // Latest
    open fun latestUpdatesRequest(page: Int): Request = GET(baseUrl, headers)
    open fun latestUpdatesParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getLatestUpdates(page: Int): MangasPage {
        val response = client.newCall(latestUpdatesRequest(page)).awaitSuccess()
        return latestUpdatesParse(response)
    }

    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getLatestUpdates(page) }
        }
    }

    // Details & Chapters
    open fun mangaDetailsRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    open fun mangaDetailsParse(response: Response): SManga = SManga.create()

    open fun chapterListRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    open fun chapterListParse(response: Response): List<SChapter> = emptyList()

    open suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean
    ): SMangaUpdate {
        val newDetails = if (fetchDetails) {
            val response = client.newCall(mangaDetailsRequest(manga)).awaitSuccess()
            mangaDetailsParse(response).apply { initialized = true }
        } else manga

        val newChapters = if (fetchChapters) {
            val response = client.newCall(chapterListRequest(manga)).awaitSuccess()
            chapterListParse(response)
        } else chapters

        return SMangaUpdateImpl(newDetails, newChapters)
    }

    override suspend fun getMangaDetails(manga: SManga): SManga {
        return getMangaUpdate(manga, emptyList(), fetchDetails = true, fetchChapters = false).manga
    }

    override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getMangaDetails(manga) }
        }
    }

    override suspend fun getChapterList(manga: SManga): List<SChapter> {
        return getMangaUpdate(manga, emptyList(), fetchDetails = false, fetchChapters = true).chapters
    }

    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getChapterList(manga) }
        }
    }

    // Pages
    open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)
    open fun pageListParse(response: Response): List<Page> = emptyList()

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val response = client.newCall(pageListRequest(chapter)).awaitSuccess()
        return pageListParse(response)
    }

    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getPageList(chapter) }
        }
    }

    open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)
    open fun imageUrlParse(response: Response): String = ""

    override suspend fun getImageUrl(page: Page): String {
        val response = client.newCall(imageUrlRequest(page)).awaitSuccess()
        return imageUrlParse(response)
    }

    override fun fetchImageUrl(page: Page): Observable<String> {
        return Observable.fromCallable {
            kotlinx.coroutines.runBlocking { getImageUrl(page) }
        }
    }

    override fun getFilterList(): FilterList = FilterList()
}

abstract class ParsedHttpSource : HttpSource() {
    override fun popularMangaParse(response: Response): MangasPage {
        val document = response.asJsoup()
        val mangas = document.select(popularMangaSelector()).map { element ->
            popularMangaFromElement(element)
        }
        val hasNextPage = popularMangaNextPageSelector()?.let { selector ->
            document.select(selector).first() != null
        } ?: false
        return MangasPage(mangas, hasNextPage)
    }

    abstract fun popularMangaSelector(): String
    abstract fun popularMangaFromElement(element: Element): SManga
    abstract fun popularMangaNextPageSelector(): String?

    override fun latestUpdatesParse(response: Response): MangasPage {
        val document = response.asJsoup()
        val mangas = document.select(latestUpdatesSelector()).map { element ->
            latestUpdatesFromElement(element)
        }
        val hasNextPage = latestUpdatesNextPageSelector()?.let { selector ->
            document.select(selector).first() != null
        } ?: false
        return MangasPage(mangas, hasNextPage)
    }

    abstract fun latestUpdatesSelector(): String
    abstract fun latestUpdatesFromElement(element: Element): SManga
    abstract fun latestUpdatesNextPageSelector(): String?

    override fun searchMangaParse(response: Response): MangasPage {
        val document = response.asJsoup()
        val mangas = document.select(searchMangaSelector()).map { element ->
            searchMangaFromElement(element)
        }
        val hasNextPage = searchMangaNextPageSelector()?.let { selector ->
            document.select(selector).first() != null
        } ?: false
        return MangasPage(mangas, hasNextPage)
    }

    abstract fun searchMangaSelector(): String
    abstract fun searchMangaFromElement(element: Element): SManga
    abstract fun searchMangaNextPageSelector(): String?

    override fun mangaDetailsParse(response: Response): SManga {
        return mangaDetailsParse(response.asJsoup())
    }

    abstract fun mangaDetailsParse(document: Document): SManga

    override fun chapterListParse(response: Response): List<SChapter> {
        val document = response.asJsoup()
        return document.select(chapterListSelector()).map { element ->
            chapterFromElement(element)
        }
    }

    abstract fun chapterListSelector(): String
    abstract fun chapterFromElement(element: Element): SChapter

    override fun pageListParse(response: Response): List<Page> {
        return pageListParse(response.asJsoup())
    }

    abstract fun pageListParse(document: Document): List<Page>

    override fun imageUrlParse(response: Response): String {
        return imageUrlParse(response.asJsoup())
    }

    abstract fun imageUrlParse(document: Document): String
}
