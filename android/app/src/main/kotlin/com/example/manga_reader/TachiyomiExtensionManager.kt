package com.example.manga_reader

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import dalvik.system.PathClassLoader
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile

class TachiyomiExtensionManager(private val context: Context) {
    private val TAG = "TachiyomiExtMgr"
    private val sourceCache = ConcurrentHashMap<String, CatalogueSource>()

    init {
        setupInjekt()
    }

    private fun setupInjekt() {
        val app = try {
            context.applicationContext as? Application
        } catch (_: Throwable) { null }
        if (app != null) {
            try { Injekt.addSingleton<Application>(app) } catch (_: Throwable) {}
        }
        try { Injekt.addSingleton<Context>(context.applicationContext) } catch (_: Throwable) {}

        val netHelper = try {
            NetworkHelper(context.applicationContext)
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to create NetworkHelper: ${e.message}")
            null
        }
        if (netHelper != null) {
            try { Injekt.addSingleton<NetworkHelper>(netHelper) } catch (_: Throwable) {}
            try { Injekt.addSingleton<OkHttpClient>(netHelper.client) } catch (_: Throwable) {}
        }

        try {
            Injekt.addSingleton<SharedPreferences>(
                context.getSharedPreferences("tachiyomi_ext_shared", Context.MODE_PRIVATE)
            )
        } catch (_: Throwable) {}

        try {
            Injekt.addSingleton<Json>(
                Json {
                    ignoreUnknownKeys = true
                    isLenient = true
                    coerceInputValues = true
                    explicitNulls = false
                }
            )
        } catch (_: Throwable) {}
    }

    private fun findApkPath(pkg: String, hintPath: String?): String? {
        if (!hintPath.isNullOrEmpty()) {
            val f = File(hintPath)
            if (f.exists() && f.length() > 0) return f.absolutePath
        }

        val clean = pkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
        val possibleNames = listOf(
            "$clean.apk",
            "$pkg.apk",
            "${pkg.lowercase()}.apk"
        )

        val possibleDirs = listOfNotNull(
            File(context.cacheDir, "shiori_extensions"),
            File(context.filesDir, "shiori_extensions"),
            context.externalCacheDir?.let { File(it, "shiori_extensions") },
            System.getProperty("java.io.tmpdir")?.let { File(it, "shiori_extensions") }
        )

        for (dir in possibleDirs) {
            if (dir.exists()) {
                for (name in possibleNames) {
                    val candidate = File(dir, name)
                    if (candidate.exists() && candidate.length() > 0) {
                        return candidate.absolutePath
                    }
                }
                // Try fuzzy match in dir
                val match = dir.listFiles()?.firstOrNull { file ->
                    val n = file.name.lowercase()
                    n.endsWith(".apk") && (n.contains(clean.lowercase()) || n.contains(pkg.lowercase()))
                }
                if (match != null && match.length() > 0) {
                    return match.absolutePath
                }
            }
        }

        // Try installed system package
        try {
            val appInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getApplicationInfo(
                    pkg,
                    PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getApplicationInfo(pkg, PackageManager.GET_META_DATA)
            }
            if (!appInfo.sourceDir.isNullOrEmpty()) {
                return appInfo.sourceDir
            }
        } catch (_: Exception) {}

        return null
    }

    private fun extractExtensionClassFromApk(apkPath: String, classLoader: ClassLoader): String? {
        // 1. Direct check for modern Keiyoushi source
        try {
            val cls = Class.forName("keiyoushi.source.Generated", false, classLoader)
            if (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls)) {
                Log.i(TAG, "Resolved extension class: keiyoushi.source.Generated")
                return "keiyoushi.source.Generated"
            }
        } catch (_: Throwable) {}

        // 2. Scan AndroidManifest.xml string table inside the APK zip
        try {
            ZipFile(apkPath).use { zip ->
                val entry = zip.getEntry("AndroidManifest.xml")
                if (entry != null) {
                    val bytes = zip.getInputStream(entry).readBytes()
                    val sUtf16 = String(bytes, Charsets.UTF_16LE)
                    val sLatin1 = String(bytes, Charsets.ISO_8859_1)
                    val pattern = Regex("[a-zA-Z0-9_]+(?:\\.[a-zA-Z0-9_]+)+")
                    val candidates = mutableSetOf<String>()
                    pattern.findAll(sUtf16).forEach { candidates.add(it.value) }
                    pattern.findAll(sLatin1).forEach { candidates.add(it.value) }

                    for (candidate in candidates) {
                        if (candidate.startsWith("android.") || candidate.startsWith("http") || candidate.contains("schemas.")) continue
                        try {
                            val cls = Class.forName(candidate, false, classLoader)
                            if (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls)) {
                                Log.i(TAG, "Resolved extension class via manifest scan: $candidate")
                                return candidate
                            }
                        } catch (_: Throwable) {}
                    }
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Manifest scan failed for $apkPath: ${e.message}")
        }

        // 3. Fallback: Dex entries scan
        try {
            @Suppress("DEPRECATION")
            val dexFile = dalvik.system.DexFile(apkPath)
            val entries = dexFile.entries()
            while (entries.hasMoreElements()) {
                val candidate = entries.nextElement()
                if (candidate.startsWith("android.") || candidate.startsWith("kotlin.") || candidate.startsWith("okhttp3.")) continue
                try {
                    val cls = Class.forName(candidate, false, classLoader)
                    if (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls)) {
                        Log.i(TAG, "Resolved extension class via dex scan: $candidate")
                        return candidate
                    }
                } catch (_: Throwable) {}
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Dex scan failed for $apkPath: ${e.message}")
        }

        return null
    }

    @Synchronized
    fun getOrLoadSource(pkg: String, hintPath: String? = null): CatalogueSource {
        sourceCache[pkg]?.let { return it }

        val apkPath = findApkPath(pkg, hintPath)
            ?: throw IllegalStateException("Extension APK for package '$pkg' not found on device.")

        Log.d(TAG, "Loading extension for $pkg from $apkPath")

        val classLoader = PathClassLoader(apkPath, context.classLoader)

        // Find main class
        var className: String? = null
        try {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageArchiveInfo(
                    apkPath,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_META_DATA.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageArchiveInfo(apkPath, PackageManager.GET_META_DATA)
            }
            val metaData = packageInfo?.applicationInfo?.metaData
            className = metaData?.getString("tachiyomi.extension.class")
                ?: metaData?.getString("tachiyomi.source.class")
                ?: metaData?.getString("tachiyomi.extension.factory")
        } catch (e: Exception) {
            Log.w(TAG, "Could not read packageArchiveInfo meta-data: ${e.message}")
        }

        if (className.isNullOrEmpty()) {
            // Check installed package metadata
            try {
                val appInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.packageManager.getApplicationInfo(
                        pkg,
                        PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong())
                    )
                } else {
                    @Suppress("DEPRECATION")
                    context.packageManager.getApplicationInfo(pkg, PackageManager.GET_META_DATA)
                }
                className = appInfo.metaData?.getString("tachiyomi.extension.class")
                    ?: appInfo.metaData?.getString("tachiyomi.source.class")
            } catch (_: Exception) {}
        }

        if (className.isNullOrEmpty()) {
            className = extractExtensionClassFromApk(apkPath, classLoader)
        }

        if (className.isNullOrEmpty()) {
            // Check common package naming conventions
            val simpleName = pkg.substringAfterLast('.')
            val capitalized = simpleName.replaceFirstChar { it.uppercase() }
            val potentialNames = listOf(
                "$pkg.$capitalized",
                "$pkg.$simpleName",
                "eu.kanade.tachiyomi.extension.$simpleName.$capitalized"
            )
            for (pName in potentialNames) {
                try {
                    val cls = Class.forName(pName, false, classLoader)
                    if (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls)) {
                        className = pName
                        break
                    }
                } catch (_: Throwable) {}
            }
        }

        if (className.isNullOrEmpty()) {
            throw IllegalStateException("Cannot resolve extension class name for $pkg in $apkPath")
        }

        if (className.startsWith(".")) {
            className = pkg + className
        }

        Log.d(TAG, "Instantiating extension class $className")
        val loadedClass = Class.forName(className, false, classLoader)

        val source: CatalogueSource = when {
            SourceFactory::class.java.isAssignableFrom(loadedClass) -> {
                val factory = loadedClass.getDeclaredConstructor().newInstance() as SourceFactory
                val sources = factory.createSources()
                sources.filterIsInstance<CatalogueSource>().firstOrNull()
                    ?: throw IllegalStateException("SourceFactory $className produced no CatalogueSources")
            }
            CatalogueSource::class.java.isAssignableFrom(loadedClass) -> {
                loadedClass.getDeclaredConstructor().newInstance() as CatalogueSource
            }
            else -> {
                throw IllegalStateException("Class $className does not implement CatalogueSource or SourceFactory")
            }
        }

        sourceCache[pkg] = source
        return source
    }

    fun removeSource(pkg: String) {
        sourceCache.remove(pkg)
    }

    fun clearCache() {
        sourceCache.clear()
    }

    private fun applyTypeFilter(filters: FilterList, type: String?) {
        if (type.isNullOrBlank() || type.equals("all", ignoreCase = true)) return
        val target = type.lowercase().trim()

        for (filter in filters) {
            when (filter) {
                is Filter.Select<*> -> {
                    val nameLower = filter.name.lowercase()
                    if (nameLower.contains("origin") || nameLower.contains("type") || 
                        nameLower.contains("demographic") || nameLower.contains("format") ||
                        nameLower.contains("country")) {
                        for (i in filter.values.indices) {
                            val valStr = filter.values[i]?.toString()?.lowercase() ?: ""
                            if (target == "manhwa" && (valStr.contains("manhwa") || valStr.contains("korean"))) {
                                filter.state = i
                                break
                            } else if (target == "manhua" && (valStr.contains("manhua") || valStr.contains("chinese"))) {
                                filter.state = i
                                break
                            } else if (target == "manga" && (valStr.contains("manga") || valStr.contains("japanese"))) {
                                filter.state = i
                                break
                            }
                        }
                    }
                }
                is Filter.Group<*> -> {
                    for (item in filter.state) {
                        if (item is Filter.CheckBox) {
                            val itemLower = item.name.lowercase()
                            if (target == "manhwa" && (itemLower.contains("manhwa") || itemLower.contains("webtoon"))) {
                                item.state = true
                            } else if (target == "manhua" && itemLower.contains("manhua")) {
                                item.state = true
                            } else if (target == "manga" && itemLower == "manga") {
                                item.state = true
                            }
                        } else if (item is Filter.TriState) {
                            val itemLower = item.name.lowercase()
                            if (target == "manhwa" && (itemLower.contains("manhwa") || itemLower.contains("webtoon"))) {
                                item.state = Filter.TriState.STATE_INCLUDE
                            } else if (target == "manhua" && itemLower.contains("manhua")) {
                                item.state = Filter.TriState.STATE_INCLUDE
                            } else if (target == "manga" && itemLower == "manga") {
                                item.state = Filter.TriState.STATE_INCLUDE
                            }
                        }
                    }
                }
                else -> {}
            }
        }
    }

    suspend fun fetchPopularManga(
        pkg: String,
        page: Int,
        type: String? = null,
        hintPath: String? = null
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val source = getOrLoadSource(pkg, hintPath)

        // If a specific type (manhwa, manhua) is requested, attempt filter search with getSearchManga
        if (!type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
            try {
                val filters = source.getFilterList()
                applyTypeFilter(filters, type)
                val filterSearchPage = try {
                    source.getSearchManga(page, "", filters)
                } catch (e: NoSuchMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                }
                if (filterSearchPage.mangas.isNotEmpty()) {
                    return@withContext filterSearchPage.mangas.map { sMangaToMap(it) }
                }
            } catch (e: Throwable) {
                Log.d(TAG, "Filtering popular manga with type '$type' via getSearchManga failed for $pkg: ${e.message}")
            }
        }

        var lastError: Throwable? = null
        var mangasPage = try {
            try {
                source.getPopularManga(page)
            } catch (e: NoSuchMethodError) {
                source.fetchPopularManga(page).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchPopularManga(page).toBlocking().first()
            }
        } catch (e: Throwable) {
            lastError = e
            Log.w(TAG, "getPopularManga failed for $pkg: ${e.message}")
            null
        }

        if (mangasPage == null || mangasPage.mangas.isEmpty()) {
            try {
                mangasPage = try {
                    source.getLatestUpdates(page)
                } catch (e: NoSuchMethodError) {
                    source.fetchLatestUpdates(page).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchLatestUpdates(page).toBlocking().first()
                }
            } catch (e: Throwable) {
                if (lastError == null) lastError = e
                Log.w(TAG, "getLatestUpdates failed for $pkg: ${e.message}")
            }
        }

        if (mangasPage == null && lastError != null) {
            throw lastError
        }

        val items = mangasPage?.mangas?.map { sMangaToMap(it) } ?: emptyList()
        if (items.isNotEmpty() && !type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
            val target = type.lowercase()
            val filtered = items.filter { item ->
                val genre = (item["genre"] as? String)?.lowercase() ?: ""
                val title = (item["title"] as? String)?.lowercase() ?: ""
                val url = (item["url"] as? String)?.lowercase() ?: ""
                val combined = "$genre $title $url"
                if (target == "manhwa") combined.contains("manhwa") || combined.contains("webtoon")
                else if (target == "manhua") combined.contains("manhua")
                else !combined.contains("manhwa") && !combined.contains("manhua")
            }
            if (filtered.isNotEmpty()) return@withContext filtered
        }
        items
    }

    suspend fun searchManga(
        pkg: String,
        query: String,
        page: Int,
        type: String? = null,
        hintPath: String? = null
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val source = getOrLoadSource(pkg, hintPath)
        val trimmed = query.trim()

        if (trimmed.isEmpty()) {
            return@withContext fetchPopularManga(pkg, page, type, hintPath)
        }

        // Extensions like Comick, MangaDex throw an Exception if query < 3 chars.
        // Instead of letting it crash and show "No titles found", match locally on popular list.
        if (trimmed.length < 3) {
            val popular = fetchPopularManga(pkg, 1, type, hintPath)
            val filtered = popular.filter {
                (it["title"] as? String)?.contains(trimmed, ignoreCase = true) == true
            }
            return@withContext if (filtered.isNotEmpty()) filtered else popular
        }

        val filters = try {
            source.getFilterList()
        } catch (e: Throwable) {
            Log.w(TAG, "getFilterList failed for $pkg: ${e.message}")
            FilterList()
        }
        applyTypeFilter(filters, type)

        var mangasPage: MangasPage? = null
        try {
            mangasPage = try {
                source.getSearchManga(page, trimmed, filters)
            } catch (e: NoSuchMethodError) {
                source.fetchSearchManga(page, trimmed, filters).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchSearchManga(page, trimmed, filters).toBlocking().first()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "searchManga with filters failed for $pkg: ${e.message}")
            try {
                val cleanFilters = source.getFilterList()
                mangasPage = try {
                    source.getSearchManga(page, trimmed, cleanFilters)
                } catch (inner: NoSuchMethodError) {
                    source.fetchSearchManga(page, trimmed, cleanFilters).toBlocking().first()
                } catch (inner: AbstractMethodError) {
                    source.fetchSearchManga(page, trimmed, cleanFilters).toBlocking().first()
                }
            } catch (inner: Throwable) {
                Log.w(TAG, "searchManga with clean filters failed for $pkg: ${inner.message}")
            }
        }

        val results = mangasPage?.mangas?.map { sMangaToMap(it) } ?: emptyList()

        if (results.isNotEmpty() && !type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
            val target = type.lowercase()
            val filtered = results.filter { item ->
                val genre = (item["genre"] as? String)?.lowercase() ?: ""
                val title = (item["title"] as? String)?.lowercase() ?: ""
                val url = (item["url"] as? String)?.lowercase() ?: ""
                val combined = "$genre $title $url"
                if (target == "manhwa") combined.contains("manhwa") || combined.contains("webtoon")
                else if (target == "manhua") combined.contains("manhua")
                else true
            }
            return@withContext if (filtered.isNotEmpty()) filtered else results
        }

        results
    }

    suspend fun fetchMangaDetails(pkg: String, url: String, title: String?, hintPath: String? = null): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val sManga = SManga.create().apply {
                this.url = url
                if (!title.isNullOrEmpty()) this.title = title
            }
            val details = try {
                try {
                    source.getMangaDetails(sManga)
                } catch (e: NoSuchMethodError) {
                    source.fetchMangaDetails(sManga).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchMangaDetails(sManga).toBlocking().first()
                }
            } catch (e: Throwable) {
                try {
                    source.fetchMangaDetails(sManga).toBlocking().first()
                } catch (_: Throwable) {
                    throw e
                }
            }
            if (details.url.isEmpty()) details.url = url
            if (details.title.isEmpty() && !title.isNullOrEmpty()) details.title = title
            sMangaToMap(details)
        }

    suspend fun fetchChapterList(pkg: String, url: String, title: String?, hintPath: String? = null): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val sManga = SManga.create().apply {
                this.url = url
                if (!title.isNullOrEmpty()) this.title = title
            }
            val chapters = try {
                try {
                    source.getChapterList(sManga)
                } catch (e: NoSuchMethodError) {
                    source.fetchChapterList(sManga).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchChapterList(sManga).toBlocking().first()
                }
            } catch (e: Throwable) {
                try {
                    source.fetchChapterList(sManga).toBlocking().first()
                } catch (_: Throwable) {
                    throw e
                }
            }
            chapters.map { sChapterToMap(it) }
        }

    suspend fun fetchPageList(pkg: String, chapterUrl: String, hintPath: String? = null): List<String> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val sChapter = SChapter.create().apply {
                this.url = chapterUrl
            }
            val pages = try {
                try {
                    source.getPageList(sChapter)
                } catch (e: NoSuchMethodError) {
                    source.fetchPageList(sChapter).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchPageList(sChapter).toBlocking().first()
                }
            } catch (e: Throwable) {
                try {
                    source.fetchPageList(sChapter).toBlocking().first()
                } catch (_: Throwable) {
                    throw e
                }
            }

            pages.map { page ->
                var imgUrl = page.imageUrl
                if (imgUrl.isNullOrEmpty() && page.url.isNotEmpty()) {
                    try {
                        imgUrl = try {
                            source.getImageUrl(page)
                        } catch (e: NoSuchMethodError) {
                            source.fetchImageUrl(page).toBlocking().first()
                        } catch (e: AbstractMethodError) {
                            source.fetchImageUrl(page).toBlocking().first()
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to fetch image URL for page ${page.index}: ${e.message}")
                    }
                }
                imgUrl ?: page.url
            }
        }

    private fun sMangaToMap(sManga: SManga): Map<String, Any?> = mapOf(
        "url" to sManga.url,
        "title" to sManga.title,
        "artist" to (sManga.artist ?: ""),
        "author" to (sManga.author ?: ""),
        "description" to (sManga.description ?: ""),
        "genre" to (sManga.genre ?: ""),
        "status" to sManga.status,
        "thumbnail_url" to (sManga.thumbnail_url ?: "")
    )

    private fun sChapterToMap(sChapter: SChapter): Map<String, Any?> = mapOf(
        "url" to sChapter.url,
        "name" to sChapter.name,
        "date_upload" to sChapter.date_upload,
        "chapter_number" to sChapter.chapter_number,
        "scanlator" to (sChapter.scanlator ?: "")
    )
}
