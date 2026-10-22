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
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class TachiyomiExtensionManager(private val context: Context) {
    private val TAG = "TachiyomiExtMgr"
    private val sourceCache = ConcurrentHashMap<String, CatalogueSource>()

    init {
        setupInjekt()
    }

    private fun setupInjekt() {
        try {
            Injekt.addSingleton<Application>(context.applicationContext as Application)
            Injekt.addSingleton<Context>(context.applicationContext)
            Injekt.addSingleton<NetworkHelper>(NetworkHelper(context.applicationContext))
            Injekt.addSingleton<SharedPreferences>(
                context.getSharedPreferences("tachiyomi_ext_shared", Context.MODE_PRIVATE)
            )
            Injekt.addSingleton<Json>(
                Json {
                    ignoreUnknownKeys = true
                    isLenient = true
                    coerceInputValues = true
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing Injekt: ${e.message}", e)
        }
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
            context.externalCacheDir?.let { File(it, "shiori_extensions") }
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

    suspend fun fetchPopularManga(pkg: String, page: Int, hintPath: String? = null): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val mangasPage = try {
                source.getPopularManga(page)
            } catch (e: NoSuchMethodError) {
                source.fetchPopularManga(page).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchPopularManga(page).toBlocking().first()
            }
            mangasPage.mangas.map { sMangaToMap(it) }
        }

    suspend fun searchManga(pkg: String, query: String, page: Int, hintPath: String? = null): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val mangasPage = try {
                source.getSearchManga(page, query, FilterList())
            } catch (e: NoSuchMethodError) {
                source.fetchSearchManga(page, query, FilterList()).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchSearchManga(page, query, FilterList()).toBlocking().first()
            }
            mangasPage.mangas.map { sMangaToMap(it) }
        }

    suspend fun fetchMangaDetails(pkg: String, url: String, title: String?, hintPath: String? = null): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val source = getOrLoadSource(pkg, hintPath)
            val sManga = SManga.create().apply {
                this.url = url
                if (!title.isNullOrEmpty()) this.title = title
            }
            val details = try {
                source.getMangaDetails(sManga)
            } catch (e: NoSuchMethodError) {
                source.fetchMangaDetails(sManga).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchMangaDetails(sManga).toBlocking().first()
            }
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
                source.getChapterList(sManga)
            } catch (e: NoSuchMethodError) {
                source.fetchChapterList(sManga).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchChapterList(sManga).toBlocking().first()
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
                source.getPageList(sChapter)
            } catch (e: NoSuchMethodError) {
                source.fetchPageList(sChapter).toBlocking().first()
            } catch (e: AbstractMethodError) {
                source.fetchPageList(sChapter).toBlocking().first()
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
