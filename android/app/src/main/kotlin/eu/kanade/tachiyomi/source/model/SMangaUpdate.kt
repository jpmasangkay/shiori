package eu.kanade.tachiyomi.source.model

open class SMangaUpdate(
    var manga: SManga = SManga.create(),
    var chapters: List<SChapter> = emptyList()
) {
    companion object {
        fun create(): SMangaUpdate = SMangaUpdate()
    }
}

class SMangaUpdateImpl(
    manga: SManga = SManga.create(),
    chapters: List<SChapter> = emptyList()
) : SMangaUpdate(manga, chapters)
