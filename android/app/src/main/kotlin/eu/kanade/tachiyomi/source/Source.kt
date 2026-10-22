package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import rx.Observable

interface Source {
    val id: Long
    val name: String
    val lang: String

    suspend fun getMangaDetails(manga: SManga): SManga
    fun fetchMangaDetails(manga: SManga): Observable<SManga>

    suspend fun getChapterList(manga: SManga): List<SChapter>
    fun fetchChapterList(manga: SManga): Observable<List<SChapter>>

    suspend fun getPageList(chapter: SChapter): List<Page>
    fun fetchPageList(chapter: SChapter): Observable<List<Page>>

    suspend fun getImageUrl(page: Page): String
    fun fetchImageUrl(page: Page): Observable<String> = Observable.just(page.imageUrl ?: page.url)
}

interface CatalogueSource : Source {
    val supportsLatest: Boolean

    suspend fun getPopularManga(page: Int): MangasPage
    fun fetchPopularManga(page: Int): Observable<MangasPage>

    suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage
    fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage>

    suspend fun getLatestUpdates(page: Int): MangasPage
    fun fetchLatestUpdates(page: Int): Observable<MangasPage>

    fun getFilterList(): FilterList = FilterList()
}

interface SourceFactory {
    fun createSources(): List<Source>
}

interface ConfigurableSource : Source {
    fun setupPreferenceScreen(screen: androidx.preference.PreferenceScreen)
}

interface UnmeteredSource : Source
