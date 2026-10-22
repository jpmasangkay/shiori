package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
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
        get() = try { network.client } catch (_: Exception) { OkHttpClient.Builder().build() }

    open val headers: Headers by lazy { headersBuilder().build() }

    // Popular
    open fun popularMangaRequest(page: Int): Request = GET(baseUrl, headers)
    open fun popularMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)
    override fun fetchPopularManga(page: Int): Observable<MangasPage> {
        return client.newCall(popularMangaRequest(page))
            .asObservableSuccess()
            .map { response -> popularMangaParse(response) }
    }

    // Search
    open fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = GET(baseUrl, headers)
    open fun searchMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)
    override fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> {
        return client.newCall(searchMangaRequest(page, query, filters))
            .asObservableSuccess()
            .map { response -> searchMangaParse(response) }
    }

    // Latest
    open fun latestUpdatesRequest(page: Int): Request = GET(baseUrl, headers)
    open fun latestUpdatesParse(response: Response): MangasPage = MangasPage(emptyList(), false)
    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> {
        return client.newCall(latestUpdatesRequest(page))
            .asObservableSuccess()
            .map { response -> latestUpdatesParse(response) }
    }

    // Details
    open fun mangaDetailsRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    open fun mangaDetailsParse(response: Response): SManga = SManga.create()
    override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
        return client.newCall(mangaDetailsRequest(manga))
            .asObservableSuccess()
            .map { response -> mangaDetailsParse(response).apply { initialized = true } }
    }

    // Chapters
    open fun chapterListRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    open fun chapterListParse(response: Response): List<SChapter> = emptyList()
    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
        return client.newCall(chapterListRequest(manga))
            .asObservableSuccess()
            .map { response -> chapterListParse(response) }
    }

    // Pages
    open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)
    open fun pageListParse(response: Response): List<Page> = emptyList()
    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
        return client.newCall(pageListRequest(chapter))
            .asObservableSuccess()
            .map { response -> pageListParse(response) }
    }

    open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)
    open fun imageUrlParse(response: Response): String = ""
    override fun fetchImageUrl(page: Page): Observable<String> {
        return client.newCall(imageUrlRequest(page))
            .asObservableSuccess()
            .map { response -> imageUrlParse(response) }
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
