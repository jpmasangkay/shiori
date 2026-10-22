package eu.kanade.tachiyomi.source.model

interface SMangaUpdate {
    var manga: SManga
    var chapters: List<SChapter>

    companion object {
        fun create(): SMangaUpdate = SMangaUpdateImpl()
    }
}

class SMangaUpdateImpl(
    override var manga: SManga = SManga.create(),
    override var chapters: List<SChapter> = emptyList()
) : SMangaUpdate
