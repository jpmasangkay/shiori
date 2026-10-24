package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.network.awaitSingle
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

    open fun setUrlWithoutDomain(manga: SManga, url: String) {
        manga.url = getUrlWithoutDomain(url)
    }

    open fun setUrlWithoutDomain(chapter: SChapter, url: String) {
        chapter.url = getUrlWithoutDomain(url)
    }

    open fun getUrlWithoutDomain(orig: String): String {
        return try {
            val uri = java.net.URI(orig.replace(" ", "%20"))
            var out = uri.path ?: ""
            if (uri.query != null) {
                out += "?" + uri.query
            }
            if (uri.fragment != null) {
                out += "#" + uri.fragment
            }
            out
        } catch (_: Throwable) {
            orig
        }
    }

    // Popular
    open fun popularMangaRequest(page: Int): Request = GET(baseUrl, headers)
    open fun popularMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getPopularManga(page: Int): MangasPage {
        return fetchPopularManga(page).awaitSingle()
    }

    override fun fetchPopularManga(page: Int): Observable<MangasPage> {
        return Observable.defer {
            try {
                val response = client.newCall(popularMangaRequest(page)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(popularMangaParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
        }
    }

    // Search
    open fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = GET(baseUrl, headers)
    open fun searchMangaParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        return fetchSearchManga(page, query, filters).awaitSingle()
    }

    override fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> {
        return Observable.defer {
            try {
                val response = client.newCall(searchMangaRequest(page, query, filters)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(searchMangaParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
        }
    }

    // Latest
    open fun latestUpdatesRequest(page: Int): Request = GET(baseUrl, headers)
    open fun latestUpdatesParse(response: Response): MangasPage = MangasPage(emptyList(), false)

    override suspend fun getLatestUpdates(page: Int): MangasPage {
        return fetchLatestUpdates(page).awaitSingle()
    }

    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> {
        return Observable.defer {
            try {
                val response = client.newCall(latestUpdatesRequest(page)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(latestUpdatesParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
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
        return fetchMangaDetails(manga).awaitSingle()
    }

    override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
        return Observable.defer {
            try {
                val response = client.newCall(mangaDetailsRequest(manga)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(mangaDetailsParse(response).apply { initialized = true })
            } catch (e: Throwable) {
                Observable.error(e)
            }
        }
    }

    override suspend fun getChapterList(manga: SManga): List<SChapter> {
        return fetchChapterList(manga).awaitSingle()
    }

    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
        return Observable.defer {
            try {
                val response = client.newCall(chapterListRequest(manga)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(chapterListParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
        }
    }

    // Pages
    open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)
    open fun pageListParse(response: Response): List<Page> = emptyList()

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        return fetchPageList(chapter).awaitSingle()
    }

    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
        return Observable.defer {
            try {
                val response = client.newCall(pageListRequest(chapter)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(pageListParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
        }
    }

    open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)
    open fun imageUrlParse(response: Response): String = ""

    open fun imageRequest(page: Page): Request = GET(page.imageUrl ?: page.url, headers)

    open val supportsRelatedMangas: Boolean get() = false
    open val disableRelatedMangas: Boolean get() = false
    open val disableRelatedMangasBySearch: Boolean get() = false

    override suspend fun getImageUrl(page: Page): String {
        return fetchImageUrl(page).awaitSingle()
    }

    override fun fetchImageUrl(page: Page): Observable<String> {
        return Observable.defer {
            try {
                val response = client.newCall(imageUrlRequest(page)).execute()
                if (!response.isSuccessful) {
                    val code = response.code
                    try { response.close() } catch (_: Throwable) {}
                    throw HttpException(code)
                }
                Observable.just(imageUrlParse(response))
            } catch (e: Throwable) {
                Observable.error(e)
            }
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
        val hasNextPage = popularMangaNextPageSelector()?.takeIf { it.isNotBlank() }?.let { selector ->
            try { document.select(selector).first() != null } catch (_: Throwable) { false }
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
        val hasNextPage = latestUpdatesNextPageSelector()?.takeIf { it.isNotBlank() }?.let { selector ->
            try { document.select(selector).first() != null } catch (_: Throwable) { false }
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
        val hasNextPage = searchMangaNextPageSelector()?.takeIf { it.isNotBlank() }?.let { selector ->
            try { document.select(selector).first() != null } catch (_: Throwable) { false }
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
