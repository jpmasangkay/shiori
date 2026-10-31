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
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
    private val mangaCache = ConcurrentHashMap<String, SManga>()
    private val chapterCache = ConcurrentHashMap<String, SChapter>()
    private val updateLocks = ConcurrentHashMap<String, Mutex>()
    private val mangaUpdateSupport = ConcurrentHashMap<Class<*>, Boolean>()

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
            if (!java.lang.reflect.Modifier.isAbstract(cls.modifiers) &&
                (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls))) {
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
                            if (!java.lang.reflect.Modifier.isAbstract(cls.modifiers) &&
                                (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls))) {
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
                    if (!java.lang.reflect.Modifier.isAbstract(cls.modifiers) &&
                        (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls))) {
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
                    if (!java.lang.reflect.Modifier.isAbstract(cls.modifiers) &&
                        (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls))) {
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
                val sources = factory.createSources().filterIsInstance<CatalogueSource>()
                val pkgLang = if (pkg.contains(".extension.")) {
                    pkg.substringAfter(".extension.").substringBefore('.').lowercase()
                } else {
                    val parts = pkg.split('.')
                    if (parts.size >= 5) parts[4].lowercase() else ""
                }
                val matching = if (pkgLang.isNotEmpty() && pkgLang != "all") {
                    sources.firstOrNull { it.lang.lowercase() == pkgLang }
                } else null
                matching ?: sources.firstOrNull { it.lang.lowercase() == "en" }
                    ?: sources.firstOrNull()
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
        val prefix = "$pkg:"
        mangaCache.keys.filter { it.startsWith(prefix) }.forEach { mangaCache.remove(it) }
        chapterCache.keys.filter { it.startsWith(prefix) }.forEach { chapterCache.remove(it) }
    }

    fun clearCache() {
        sourceCache.clear()
        mangaCache.clear()
        chapterCache.clear()
    }

    fun getSourceBaseUrl(pkg: String, hintPath: String? = null): String? {
        return try {
            val src = getOrLoadSource(pkg, hintPath)
            if (src is HttpSource) src.baseUrl else null
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Modern extensions (keiyoushi KeiSource) only implement [HttpSource.getMangaUpdate] and leave
     * getMangaDetails/getChapterList at the base-class default, which would request
     * `baseUrl + manga.url` (e.g. "https://comick.live" + "some-slug"). Detect that case.
     */
    private fun supportsMangaUpdate(source: CatalogueSource): Boolean {
        if (source !is HttpSource) return false
        return mangaUpdateSupport.getOrPut(source.javaClass) {
            try {
                // 1. Check class hierarchy for KeiSource or declared getMangaUpdate / fetchMangaUpdate
                var cls: Class<*>? = source.javaClass
                while (cls != null && cls != HttpSource::class.java && cls != Any::class.java) {
                    if (cls.name == "keiyoushi.source.KeiSource" || cls.simpleName == "KeiSource") {
                        return@getOrPut true
                    }
                    if (cls.declaredMethods.any { it.name == "getMangaUpdate" || it.name == "fetchMangaUpdate" }) {
                        return@getOrPut true
                    }
                    cls = cls.superclass
                }
                source.javaClass.methods.any {
                    (it.name == "getMangaUpdate" || it.name == "fetchMangaUpdate") &&
                    it.declaringClass != HttpSource::class.java
                }
            } catch (_: Throwable) {
                false
            }
        }
    }

    private fun getSafeFilterList(source: CatalogueSource): FilterList {
        return try {
            source.getFilterList()
        } catch (e: Throwable) {
            Log.w(TAG, "source.getFilterList() failed for ${source.name}: ${e.message}")
            try {
                // If it's a KeiSource or similar, try invoking getFilterList(JsonElement?) with null
                val method = source.javaClass.methods.firstOrNull {
                    it.name == "getFilterList" && it.parameterTypes.size == 1
                } ?: source.javaClass.declaredMethods.firstOrNull {
                    it.name == "getFilterList" && it.parameterTypes.size == 1
                }
                if (method != null) {
                    method.isAccessible = true
                    method.invoke(source, null) as FilterList
                } else {
                    FilterList()
                }
            } catch (_: Throwable) {
                FilterList()
            }
        }
    }

    private suspend fun fetchViaMangaUpdate(
        pkg: String,
        source: HttpSource,
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean
    ) = updateLocks.getOrPut(pkg) { Mutex() }.withLock {
        // KeiSource rejects concurrent updates for the same manga, so serialize per source.
        source.getMangaUpdate(manga, chapters, fetchDetails, fetchChapters)
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
                val filters = getSafeFilterList(source)
                applyTypeFilter(filters, type)
                filters.filterIsInstance<Filter.Sort>().forEach { sort ->
                    val values = sort.values
                    for (i in values.indices) {
                        val v = values[i].lowercase()
                        if (v.contains("popular") || v.contains("follow") || v.contains("view")) {
                            sort.state = Filter.Sort.Selection(i, false)
                            break
                        }
                    }
                }
                val filterSearchPage = try {
                    source.getSearchManga(page, "", filters)
                } catch (e: NoSuchMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                } catch (e: AbstractMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                }
                if (filterSearchPage.mangas.isNotEmpty()) {
                    filterSearchPage.mangas.forEach { m ->
                        mangaCache["$pkg:${m.url}"] = m
                    }
                    return@withContext filterSearchPage.mangas.map { sMangaToMap(it, source) }
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
            try {
                source.fetchPopularManga(page).toBlocking().first()
            } catch (rxErr: Throwable) {
                lastError = e
                Log.w(TAG, "getPopularManga failed for $pkg: ${e.message}")
                null
            }
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
                try {
                    mangasPage = source.fetchLatestUpdates(page).toBlocking().first()
                } catch (rxErr: Throwable) {
                    if (lastError == null) lastError = e
                    Log.w(TAG, "getLatestUpdates failed for $pkg: ${e.message}")
                }
            }
        }

        if (mangasPage == null && lastError != null) {
            throw lastError
        }

        mangasPage?.mangas?.forEach { m ->
            mangaCache["$pkg:${m.url}"] = m
        }

        val items = mangasPage?.mangas?.map { sMangaToMap(it, source) } ?: emptyList()
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

        var mangasPage: MangasPage? = null
        var lastSearchError: Throwable? = null

        // 1. Try search with configured filters (including type filter if requested)
        try {
            val filters = getSafeFilterList(source)
            if (!type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
                applyTypeFilter(filters, type)
            }
            mangasPage = try {
                source.getSearchManga(page, trimmed, filters)
            } catch (e: NoSuchMethodError) {
                source.fetchSearchManga(page, trimmed, filters).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchSearchManga(page, trimmed, filters).toBlocking().first()
            }
        } catch (e: Throwable) {
            lastSearchError = e
            Log.w(TAG, "Search with filters failed for $pkg (query='$trimmed'): ${e.message}")
        }

        // 2. If initial search failed or threw and type was specified, retry with clean default filters
        if (mangasPage == null && !type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
            try {
                val cleanFilters = getSafeFilterList(source)
                mangasPage = try {
                    source.getSearchManga(page, trimmed, cleanFilters)
                } catch (inner: NoSuchMethodError) {
                    source.fetchSearchManga(page, trimmed, cleanFilters).toBlocking().first()
                } catch (inner: AbstractMethodError) {
                    source.fetchSearchManga(page, trimmed, cleanFilters).toBlocking().first()
                }
                lastSearchError = null
            } catch (inner: Throwable) {
                lastSearchError = inner
                Log.w(TAG, "Search with clean filters failed for $pkg: ${inner.message}")
            }
        }

        // 3. If query is short (< 3 chars) or source rejected it, fallback to popular list match
        if (mangasPage == null && (trimmed.length < 3 || lastSearchError?.message?.contains("3 characters", ignoreCase = true) == true)) {
            try {
                val popular = fetchPopularManga(pkg, 1, type, hintPath)
                val filtered = popular.filter {
                    (it["title"] as? String)?.contains(trimmed, ignoreCase = true) == true
                }
                if (filtered.isNotEmpty()) return@withContext filtered
            } catch (_: Throwable) {}
        }

        if (mangasPage == null && lastSearchError != null) {
            throw lastSearchError
        }

        mangasPage?.mangas?.forEach { m ->
            mangaCache["$pkg:${m.url}"] = m
        }

        mangasPage?.mangas?.map { sMangaToMap(it, source) } ?: emptyList()
    }

    suspend fun fetchMangaDetails(pkg: String, url: String, title: String?, hintPath: String? = null): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val cleanUrl = if (url.startsWith("/comic/")) {
                url.removePrefix("/comic/").trim('/')
            } else if (url.contains("/comic/")) {
                url.substringAfterLast("/comic/").trim('/')
            } else {
                url
            }
            val sManga = mangaCache["$pkg:$url"] ?: mangaCache["$pkg:$cleanUrl"] ?: SManga.create().apply {
                this.url = cleanUrl
                if (!title.isNullOrEmpty()) this.title = title
            }

            var details: SManga? = null
            var lastError: Throwable? = null

            if (supportsMangaUpdate(source)) {
                try {
                    details = fetchViaMangaUpdate(pkg, source as HttpSource, sManga, emptyList(), true, false).manga
                } catch (e: Throwable) {
                    lastError = e
                    Log.w(TAG, "fetchViaMangaUpdate failed for details of $url ($pkg): ${e.message}")
                }
            }

            if (details == null) {
                try {
                    details = try {
                        source.getMangaDetails(sManga)
                    } catch (e: NoSuchMethodError) {
                        source.fetchMangaDetails(sManga).toBlocking().first()
                    } catch (e: AbstractMethodError) {
                        source.fetchMangaDetails(sManga).toBlocking().first()
                    }
                } catch (e: Throwable) {
                    try {
                        details = source.fetchMangaDetails(sManga).toBlocking().first()
                    } catch (rxErr: Throwable) {
                        if (lastError == null) lastError = e
                        Log.w(TAG, "source.getMangaDetails failed for $url ($pkg): ${e.message}")
                    }
                }
            }

            // Fallback to fetchViaMangaUpdate if standard getMangaDetails failed and wasn't tried yet
            if (details == null && !supportsMangaUpdate(source) && source is HttpSource) {
                try {
                    details = fetchViaMangaUpdate(pkg, source, sManga, emptyList(), true, false).manga
                } catch (e: Throwable) {
                    Log.w(TAG, "Fallback fetchViaMangaUpdate also failed for $url ($pkg): ${e.message}")
                }
            }

            if (details == null) {
                throw (lastError ?: IllegalStateException("Failed to load details for $url"))
            }

            if (details.url.isEmpty()) details.url = cleanUrl
            if (details.title.isEmpty() && !title.isNullOrEmpty()) details.title = title
            if (details.thumbnail_url.isNullOrEmpty() && !sManga.thumbnail_url.isNullOrEmpty()) {
                details.thumbnail_url = sManga.thumbnail_url
            }
            if (details.memo == null && sManga.memo != null) {
                details.memo = sManga.memo
            }
            mangaCache["$pkg:$url"] = details
            mangaCache["$pkg:$cleanUrl"] = details
            sMangaToMap(details, source)
        }

    suspend fun fetchChapterList(pkg: String, url: String, title: String?, hintPath: String? = null): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val cleanUrl = if (url.startsWith("/comic/")) {
                url.removePrefix("/comic/").trim('/')
            } else if (url.contains("/comic/")) {
                url.substringAfterLast("/comic/").trim('/')
            } else {
                url
            }
            val sManga = mangaCache["$pkg:$url"] ?: mangaCache["$pkg:$cleanUrl"] ?: SManga.create().apply {
                this.url = cleanUrl
                if (!title.isNullOrEmpty()) this.title = title
            }

            var chapters: List<SChapter>? = null
            var lastError: Throwable? = null

            if (supportsMangaUpdate(source)) {
                try {
                    chapters = fetchViaMangaUpdate(pkg, source as HttpSource, sManga, emptyList(), false, true).chapters
                } catch (e: Throwable) {
                    lastError = e
                    Log.w(TAG, "fetchViaMangaUpdate failed for chapters of $url ($pkg): ${e.message}")
                }
            }

            if (chapters == null) {
                try {
                    chapters = try {
                        source.getChapterList(sManga)
                    } catch (e: NoSuchMethodError) {
                        source.fetchChapterList(sManga).toBlocking().first()
                    } catch (e: AbstractMethodError) {
                        source.fetchChapterList(sManga).toBlocking().first()
                    }
                } catch (e: Throwable) {
                    try {
                        chapters = source.fetchChapterList(sManga).toBlocking().first()
                    } catch (rxErr: Throwable) {
                        if (lastError == null) lastError = e
                        Log.w(TAG, "source.getChapterList failed for $url ($pkg): ${e.message}")
                    }
                }
            }

            // Fallback to fetchViaMangaUpdate if standard getChapterList failed and wasn't tried yet
            if (chapters == null && !supportsMangaUpdate(source) && source is HttpSource) {
                try {
                    chapters = fetchViaMangaUpdate(pkg, source, sManga, emptyList(), false, true).chapters
                } catch (e: Throwable) {
                    Log.w(TAG, "Fallback fetchViaMangaUpdate also failed for chapters of $url ($pkg): ${e.message}")
                }
            }

            if (chapters == null) {
                throw (lastError ?: IllegalStateException("Failed to load chapters for $url"))
            }

            val mangaSlug = sManga.memo?.get("slug")?.toString()?.trim('"')
            chapters.forEach { c ->
                if (c.memo == null && !mangaSlug.isNullOrEmpty()) {
                    c.memo = kotlinx.serialization.json.buildJsonObject {
                        put("mangaSlug", kotlinx.serialization.json.JsonPrimitive(mangaSlug))
                        put("slug", kotlinx.serialization.json.JsonPrimitive(mangaSlug))
                    }
                }
                chapterCache["$pkg:${c.url}"] = c
                if (source is HttpSource) {
                    chapterCache["$pkg:${source.getUrlWithoutDomain(c.url)}"] = c
                }
            }
            chapters.map { sChapterToMap(it) }
        }

    suspend fun fetchPageList(pkg: String, chapterUrl: String, hintPath: String? = null): List<String> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val sChapter = chapterCache["$pkg:$chapterUrl"]
                ?: (if (source is HttpSource) chapterCache["$pkg:${source.getUrlWithoutDomain(chapterUrl)}"] else null)
                ?: SChapter.create().apply {
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

            coroutineScope {
                pages.map { page ->
                    async {
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
                        var finalUrl = imgUrl ?: page.url
                        if (finalUrl.startsWith("//")) {
                            finalUrl = "https:$finalUrl"
                        } else if (source is HttpSource && !finalUrl.startsWith("http://") && !finalUrl.startsWith("https://")) {
                            finalUrl = source.baseUrl.trimEnd('/') + "/" + finalUrl.trimStart('/')
                        }
                        if (source is HttpSource && finalUrl.isNotEmpty()) {
                            try {
                                val resolvedPage = Page(page.index, page.url, finalUrl)
                                val reqUrl = source.imageRequest(resolvedPage).url.toString()
                                if (reqUrl.startsWith("http://") || reqUrl.startsWith("https://")) {
                                    finalUrl = reqUrl
                                }
                            } catch (_: Throwable) {}
                        }
                        finalUrl
                    }
                }.awaitAll()
            }
        }

    private fun sMangaToMap(sManga: SManga, source: CatalogueSource? = null): Map<String, Any?> {
        var thumb = (sManga.thumbnail_url ?: "").trim()
        if (thumb.startsWith("//")) {
            thumb = "https:$thumb"
        } else if (thumb.isNotEmpty() && !thumb.startsWith("http://") && !thumb.startsWith("https://") && source is HttpSource) {
            thumb = source.baseUrl.trimEnd('/') + "/" + thumb.trimStart('/')
        }
        val referer = if (source is HttpSource) {
            try {
                source.headers["Referer"] ?: source.baseUrl
            } catch (_: Throwable) {
                source.baseUrl
            }
        } else {
            ""
        }
        return mapOf(
            "url" to sManga.url,
            "title" to sManga.title,
            "artist" to (sManga.artist ?: ""),
            "author" to (sManga.author ?: ""),
            "description" to (sManga.description ?: ""),
            "genre" to (sManga.genre ?: ""),
            "status" to sManga.status,
            "thumbnail_url" to thumb,
            "referer" to referer,
            "memo" to sManga.memo?.toString()
        )
    }

    private fun sChapterToMap(sChapter: SChapter): Map<String, Any?> = mapOf(
        "url" to sChapter.url,
        "name" to sChapter.name,
        "date_upload" to sChapter.date_upload,
        "chapter_number" to sChapter.chapter_number,
        "scanlator" to (sChapter.scanlator ?: ""),
        "memo" to sChapter.memo?.toString()
    )
}
