package com.example.manga_reader

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.webkit.CookieManager
import dalvik.system.PathClassLoader
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.RateLimitInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
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
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile
import android.content.pm.PackageInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable

class TachiyomiExtensionManager(private val context: Context) {
    private val TAG = "TachiyomiExtMgr"
    private val sourceCache = ConcurrentHashMap<String, CatalogueSource>()
    private val allSourcesCache = ConcurrentHashMap<String, List<CatalogueSource>>()
    private val mangaCache = ConcurrentHashMap<String, SManga>()
    private val chapterCache = ConcurrentHashMap<String, SChapter>()
    private val pageCache = ConcurrentHashMap<String, Page>()
    private val iconCache = ConcurrentHashMap<String, ByteArray>()
    private val updateLocks = ConcurrentHashMap<String, Mutex>()
    private val mangaUpdateSupport = ConcurrentHashMap<Class<*>, Boolean>()
    private val customImagePipelineSupport = ConcurrentHashMap<Class<*>, Boolean>()

    companion object {
        const val EXTENSION_FEATURE = "tachiyomi.extension"
        const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
        const val METADATA_SOURCE_FACTORY = "tachiyomi.extension.factory"
        const val METADATA_NSFW = "tachiyomi.extension.nsfw"
        const val LIB_VERSION_MIN = 1.4
        const val LIB_VERSION_MAX = 1.6

        private val STUB_PACKAGES = setOf(
            "eu.kanade.tachiyomi.extension.all.keiyoushi",
            "eu.kanade.tachiyomi.extension.all.mihon"
        )

        fun isStubPackage(pkg: String): Boolean {
            val base = pkg.substringBefore('@').trim().lowercase()
            return base in STUB_PACKAGES ||
                base.endsWith(".extension.all.keiyoushi") ||
                base.endsWith(".extension.all.mihon")
        }

        fun deriveLangFromPkg(pkg: String): String {
            val base = pkg.substringBefore('@').trim()
            if (base.contains(".extension.")) {
                val after = base.substringAfter(".extension.")
                val lang = after.substringBefore('.', "")
                if (lang.isNotEmpty()) return lang.lowercase()
            }
            val parts = base.split('.')
            if (parts.size >= 5) return parts[4].lowercase()
            return "en"
        }

        fun parseLibVersion(versionName: String?): String {
            val v = (versionName ?: "").trim()
            if (v.isEmpty()) return "1.4"
            val parts = v.split('.')
            return if (parts.size >= 2) "${parts[0]}.${parts[1]}" else v
        }

        fun isLibVersionCompatible(libVersion: String?): Boolean {
            val parsed = libVersion?.trim()?.toDoubleOrNull() ?: return true
            return parsed in LIB_VERSION_MIN..LIB_VERSION_MAX
        }
    }

    private fun splitPkgSelector(pkg: String): Pair<String, String> {
        val base = pkg.substringBefore('@').trim()
        val selector = pkg.substringAfter('@', "").trim()
        return base to selector
    }

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

        try {
            Injekt.addSingleton<kotlinx.serialization.protobuf.ProtoBuf>(
                kotlinx.serialization.protobuf.ProtoBuf.Default
            )
        } catch (_: Throwable) {}
    }

    private fun drawableToPngBytes(drawable: Drawable): ByteArray? {
        return try {
            val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                drawable.bitmap
            } else {
                val w = drawable.intrinsicWidth.coerceIn(48, 144)
                val h = drawable.intrinsicHeight.coerceIn(48, 144)
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
                bmp
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
            out.toByteArray()
        } catch (_: Throwable) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun extractSignatureSha256(pkgInfo: PackageInfo): String? {
        return try {
            val certBytes: ByteArray? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signingInfo = pkgInfo.signingInfo
                val sigs = if (signingInfo != null) {
                    if (signingInfo.hasMultipleSigners()) signingInfo.apkContentsSigners
                    else signingInfo.signingCertificateHistory
                } else null
                sigs?.firstOrNull()?.toByteArray() ?: pkgInfo.signatures?.firstOrNull()?.toByteArray()
            } else {
                pkgInfo.signatures?.firstOrNull()?.toByteArray()
            }
            if (certBytes != null) {
                MessageDigest.getInstance("SHA-256")
                    .digest(certBytes)
                    .joinToString("") { "%02x".format(it) }
            } else null
        } catch (_: Throwable) {
            null
        }
    }

    @Suppress("DEPRECATION")
    fun getApkSignatureSha256(apkPath: String): String? {
        return try {
            val pm = context.packageManager
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
            } else {
                PackageManager.GET_SIGNATURES
            }
            val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageArchiveInfo(apkPath, PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                pm.getPackageArchiveInfo(apkPath, flags)
            }
            if (pkgInfo != null) extractSignatureSha256(pkgInfo) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun isExtensionPackage(pkgInfo: PackageInfo): Boolean {
        val pkgName = pkgInfo.packageName ?: return false
        if (isStubPackage(pkgName)) return false
        val hasFeature = pkgInfo.reqFeatures?.any { it.name == EXTENSION_FEATURE } == true
        if (hasFeature) return true
        val meta = pkgInfo.applicationInfo?.metaData
        if (meta != null && (meta.containsKey(METADATA_SOURCE_CLASS) || meta.containsKey(METADATA_SOURCE_FACTORY) || meta.containsKey("tachiyomi.source.class"))) {
            return true
        }
        return pkgName.contains(".tachiyomi.extension.") || pkgName.startsWith("eu.kanade.tachiyomi.extension.")
    }

    @Suppress("DEPRECATION")
    private fun getPkgVersionCode(pkgInfo: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pkgInfo.longVersionCode
        } else {
            pkgInfo.versionCode.toLong()
        }
    }

    @Suppress("DEPRECATION")
    fun getInstalledExtensionsDetails(): List<Map<String, Any?>> {
        val pm = context.packageManager
        val flags = PackageManager.GET_CONFIGURATIONS or
            PackageManager.GET_META_DATA or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)

        val discovered = linkedMapOf<String, Pair<PackageInfo, String?>>()

        try {
            val installed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                pm.getInstalledPackages(flags)
            }
            for (pkgInfo in installed) {
                if (isExtensionPackage(pkgInfo)) {
                    discovered[pkgInfo.packageName] = pkgInfo to pkgInfo.applicationInfo?.sourceDir
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Error querying installed packages: ${e.message}")
        }

        // Scan private-storage fallback APKs ONLY for extensions not installed in PackageManager.
        // If PackageManager already owns the package, purge any stale private copy so OS versionCode stays authoritative.
        val osInstalledPackages = discovered.keys.toHashSet()
        val privateDir = File(context.filesDir, "shiori_extensions")
        if (privateDir.exists() && privateDir.isDirectory) {
            privateDir.listFiles { f -> f.extension.equals("apk", ignoreCase = true) && f.length() > 0 }?.forEach { apkFile ->
                try {
                    val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.getPackageArchiveInfo(apkFile.absolutePath, PackageManager.PackageInfoFlags.of(flags.toLong()))
                    } else {
                        pm.getPackageArchiveInfo(apkFile.absolutePath, flags)
                    }
                    if (pkgInfo != null && isExtensionPackage(pkgInfo)) {
                        if (osInstalledPackages.contains(pkgInfo.packageName)) {
                            try {
                                apkFile.setWritable(true)
                                apkFile.delete()
                            } catch (_: Throwable) {}
                        } else {
                            val candidateVer = getPkgVersionCode(pkgInfo)
                            val existingVer = discovered[pkgInfo.packageName]?.first?.let { getPkgVersionCode(it) } ?: -1L
                            if (!discovered.containsKey(pkgInfo.packageName) || candidateVer >= existingVer) {
                                pkgInfo.applicationInfo?.apply {
                                    sourceDir = apkFile.absolutePath
                                    publicSourceDir = apkFile.absolutePath
                                }
                                discovered[pkgInfo.packageName] = pkgInfo to apkFile.absolutePath
                            }
                        }
                    }
                } catch (_: Throwable) {}
            }
        }

        val result = mutableListOf<Map<String, Any?>>()
        for ((pkgName, pair) in discovered) {
            val (pkgInfo, apkPath) = pair
            val appInfo = pkgInfo.applicationInfo
            val meta = appInfo?.metaData

            val rawLabel = try {
                appInfo?.loadLabel(pm)?.toString()?.trim().orEmpty()
            } catch (_: Throwable) { "" }
            val cleanName = rawLabel
                .removePrefix("Tachiyomi: ")
                .removePrefix("Mihon: ")
                .trim()
                .ifEmpty { pkgName.substringAfterLast('.') }

            val versionName = pkgInfo.versionName ?: "1.0"
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                pkgInfo.versionCode.toLong()
            }
            val libVersion = parseLibVersion(versionName)
            val compatible = isLibVersionCompatible(libVersion)
            val lang = deriveLangFromPkg(pkgName)
            val nsfw = when (val raw = meta?.get(METADATA_NSFW)) {
                is Int -> raw == 1
                is String -> raw == "1"
                is Boolean -> raw
                else -> false
            }

            val cacheKey = "$pkgName:$versionCode"
            val iconBytes = iconCache[cacheKey] ?: try {
                val iconDrawable = appInfo?.loadIcon(pm)
                val bytes = if (iconDrawable != null) drawableToPngBytes(iconDrawable) else null
                if (bytes != null) iconCache[cacheKey] = bytes
                bytes
            } catch (_: Throwable) { null }

            val signatureHash = extractSignatureSha256(pkgInfo)

            val resolvedSources = mutableListOf<Map<String, Any?>>()
            var loadError: String? = null
            if (compatible) {
                try {
                    val loadedSources = loadAllSourcesForPkg(pkgName, apkPath)
                    for (src in loadedSources) {
                        val baseUrl = (src as? HttpSource)?.let {
                            try { it.baseUrl } catch (_: Throwable) { "" }
                        } ?: ""
                        resolvedSources.add(
                            mapOf(
                                "id" to src.id.toString(),
                                "name" to src.name,
                                "lang" to src.lang.ifEmpty { lang },
                                "baseUrl" to baseUrl,
                                "supportsLatest" to try { src.supportsLatest } catch (_: Throwable) { false }
                            )
                        )
                    }
                } catch (e: Throwable) {
                    loadError = e.message ?: e.toString()
                    Log.w(TAG, "Failed to resolve CatalogueSources for $pkgName: $loadError")
                }
            } else {
                loadError = "Incompatible lib version $libVersion"
            }

            result.add(
                mapOf(
                    "name" to cleanName,
                    "pkg" to pkgName,
                    "versionName" to versionName,
                    "versionCode" to versionCode,
                    "libVersion" to libVersion,
                    "lang" to lang,
                    "nsfw" to nsfw,
                    "isCompatible" to compatible,
                    "iconBytes" to iconBytes,
                    "apkPath" to apkPath,
                    "signatureHash" to signatureHash,
                    "sources" to resolvedSources,
                    "loadError" to loadError
                )
            )
        }

        return result
    }

    private fun findApkPath(pkg: String, hintPath: String?): String? {
        val pm = context.packageManager

        // Prefer the OS-installed system package whenever present so stale temp/cache APKs never shadow PackageManager.
        var systemSourceDir: String? = null
        var systemVersionCode = -1L
        try {
            val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(
                    pkg,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_META_DATA.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, PackageManager.GET_META_DATA)
            }
            val srcDir = pkgInfo.applicationInfo?.sourceDir
            if (!srcDir.isNullOrEmpty() && File(srcDir).exists()) {
                systemSourceDir = srcDir
                systemVersionCode = getPkgVersionCode(pkgInfo)
            }
        } catch (_: Exception) {}

        if (systemSourceDir != null) {
            if (!hintPath.isNullOrEmpty()) {
                val hintFile = File(hintPath)
                if (hintFile.exists() && hintFile.length() > 0) {
                    try {
                        val hintInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            pm.getPackageArchiveInfo(hintFile.absolutePath, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            pm.getPackageArchiveInfo(hintFile.absolutePath, 0)
                        }
                        val hintVer = if (hintInfo != null) getPkgVersionCode(hintInfo) else -1L
                        if (hintVer > systemVersionCode) {
                            return hintFile.absolutePath
                        }
                    } catch (_: Throwable) {}
                }
            }
            return systemSourceDir
        }

        val candidates = linkedSetOf<String>()
        if (!hintPath.isNullOrEmpty()) {
            val f = File(hintPath)
            if (f.exists() && f.length() > 0) candidates.add(f.absolutePath)
        }

        val clean = pkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
        val possibleNames = listOf(
            "$clean.apk",
            "$pkg.apk",
            "${pkg.lowercase()}.apk"
        )

        val possibleDirs = listOfNotNull(
            File(context.filesDir, "shiori_extensions"),
            File(context.codeCacheDir, "shiori_extensions"),
            File(context.cacheDir, "shiori_extensions"),
            context.externalCacheDir?.let { File(it, "shiori_extensions") },
            System.getProperty("java.io.tmpdir")?.let { File(it, "shiori_extensions") }
        )

        for (dir in possibleDirs) {
            if (dir.exists()) {
                for (name in possibleNames) {
                    val candidate = File(dir, name)
                    if (candidate.exists() && candidate.length() > 0) {
                        candidates.add(candidate.absolutePath)
                    }
                }
                val match = dir.listFiles()?.firstOrNull { file ->
                    val n = file.name.lowercase()
                    n.endsWith(".apk") && (n.contains(clean.lowercase()) || n.contains(pkg.lowercase()))
                }
                if (match != null && match.length() > 0) {
                    candidates.add(match.absolutePath)
                }
            }
        }

        if (candidates.isEmpty()) return null
        if (candidates.size == 1) return candidates.first()

        // Pick the APK with the highest versionCode among uninstalled fallback candidates
        var bestPath: String? = null
        var bestVersion = -1L
        for (path in candidates) {
            try {
                val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageArchiveInfo(path, 0)
                }
                val ver = if (info != null) getPkgVersionCode(info) else 0L
                if (bestPath == null || ver > bestVersion) {
                    bestVersion = ver
                    bestPath = path
                }
            } catch (_: Throwable) {
                if (bestPath == null) bestPath = path
            }
        }
        return bestPath
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

    /**
     * Stages the APK into codeCacheDir with read-only permissions (mandatory on Android 14+ / API 34+
     * where PathClassLoader throws SecurityException on writable DEX files) and extracts any bundled
     * native .so libraries (e.g. QuickJS) matching the device ABI.
     */
    private fun stageReadOnlyDexAndLibs(basePkg: String, rawApkPath: String): Pair<String, String?> {
        val srcFile = File(rawApkPath)
        val safePkg = basePkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")

        // System-installed APKs under /data/app are already read-only
        val stagedApk: File = if (rawApkPath.startsWith("/data/app/") && !srcFile.canWrite()) {
            srcFile
        } else {
            val dexDir = File(context.codeCacheDir, "shiori_dex_readonly")
            if (!dexDir.exists()) dexDir.mkdirs()
            val targetName = "${safePkg}_${srcFile.length()}_${srcFile.lastModified()}.apk"
            val targetFile = File(dexDir, targetName)
            if (!targetFile.exists() || targetFile.length() != srcFile.length()) {
                // Clean up older staged versions of this extension
                dexDir.listFiles()?.forEach { existing ->
                    if (existing.name.startsWith("${safePkg}_") && existing.name != targetName) {
                        try {
                            existing.setWritable(true)
                            existing.delete()
                        } catch (_: Throwable) {}
                    }
                }
                val tmpFile = File(dexDir, "$targetName.tmp")
                try {
                    if (tmpFile.exists()) {
                        tmpFile.setWritable(true)
                        tmpFile.delete()
                    }
                    srcFile.inputStream().use { input ->
                        tmpFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                    if (targetFile.exists()) {
                        targetFile.setWritable(true)
                        targetFile.delete()
                    }
                    if (!tmpFile.renameTo(targetFile)) {
                        srcFile.copyTo(targetFile, overwrite = true)
                        tmpFile.delete()
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "Staging APK copy warning for $basePkg: ${e.message}")
                    if (!targetFile.exists()) {
                        srcFile.setReadOnly()
                        return srcFile.absolutePath to null
                    }
                }
            }
            try {
                targetFile.setReadOnly()
            } catch (_: Throwable) {}
            targetFile
        }

        // Extract native .so libraries if the extension bundles any (e.g. QuickJS)
        var nativeLibPath: String? = null
        try {
            ZipFile(stagedApk).use { zip ->
                val abis = Build.SUPPORTED_ABIS ?: emptyArray()
                for (abi in abis) {
                    val prefix = "lib/$abi/"
                    val matchingEntries = zip.entries().asSequence()
                        .filter { !it.isDirectory && it.name.startsWith(prefix) && it.name.endsWith(".so") }
                        .toList()
                    if (matchingEntries.isNotEmpty()) {
                        val libDir = File(context.codeCacheDir, "shiori_native_libs/${safePkg}_$abi")
                        if (!libDir.exists()) libDir.mkdirs()
                        for (entry in matchingEntries) {
                            val soName = entry.name.substringAfterLast('/')
                            val outSo = File(libDir, soName)
                            if (!outSo.exists() || outSo.length() != entry.size) {
                                outSo.setWritable(true)
                                zip.getInputStream(entry).use { input ->
                                    outSo.outputStream().use { output -> input.copyTo(output) }
                                }
                                outSo.setReadOnly()
                            }
                        }
                        nativeLibPath = libDir.absolutePath
                        break
                    }
                }
            }
        } catch (_: Throwable) {}

        return stagedApk.absolutePath to nativeLibPath
    }

    @Synchronized
    private fun loadAllSourcesForPkg(basePkg: String, hintPath: String? = null): List<CatalogueSource> {
        allSourcesCache[basePkg]?.let { if (it.isNotEmpty()) return it }

        val rawApkPath = findApkPath(basePkg, hintPath)
            ?: throw IllegalStateException("Extension APK for package '$basePkg' not found on device.")

        val (apkPath, nativeLibPath) = stageReadOnlyDexAndLibs(basePkg, rawApkPath)
        Log.d(TAG, "Loading extension for $basePkg from $apkPath (nativeLibs=$nativeLibPath)")

        val classLoader = PathClassLoader(apkPath, nativeLibPath, context.classLoader)

        var manifestPkg = basePkg
        var rawClassField: String? = null
        var detectedLibVersion: String? = null
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
            if (!packageInfo?.packageName.isNullOrEmpty()) {
                manifestPkg = packageInfo!!.packageName
            }
            if (!packageInfo?.versionName.isNullOrEmpty()) {
                detectedLibVersion = parseLibVersion(packageInfo?.versionName)
            }
            val metaData = packageInfo?.applicationInfo?.metaData
            rawClassField = metaData?.getString("tachiyomi.extension.class")
                ?: metaData?.getString("tachiyomi.source.class")
                ?: metaData?.getString("tachiyomi.extension.factory")
        } catch (e: Exception) {
            Log.w(TAG, "Could not read packageArchiveInfo meta-data: ${e.message}")
        }

        if (detectedLibVersion != null && !isLibVersionCompatible(detectedLibVersion)) {
            throw IllegalStateException("Incompatible lib version $detectedLibVersion (supported: $LIB_VERSION_MIN–$LIB_VERSION_MAX)")
        }

        if (rawClassField.isNullOrEmpty()) {
            try {
                val appInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.packageManager.getApplicationInfo(
                        basePkg,
                        PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong())
                    )
                } else {
                    @Suppress("DEPRECATION")
                    context.packageManager.getApplicationInfo(basePkg, PackageManager.GET_META_DATA)
                }
                rawClassField = appInfo.metaData?.getString("tachiyomi.extension.class")
                    ?: appInfo.metaData?.getString("tachiyomi.source.class")
            } catch (_: Exception) {}
        }

        if (rawClassField.isNullOrEmpty()) {
            rawClassField = extractExtensionClassFromApk(apkPath, classLoader)
        }

        if (rawClassField.isNullOrEmpty()) {
            val simpleName = basePkg.substringAfterLast('.')
            val capitalized = simpleName.replaceFirstChar { it.uppercase() }
            val potentialNames = listOf(
                "$manifestPkg.$capitalized",
                "$manifestPkg.$simpleName",
                "$basePkg.$capitalized",
                "$basePkg.$simpleName",
                "eu.kanade.tachiyomi.extension.$simpleName.$capitalized"
            )
            for (pName in potentialNames) {
                try {
                    val cls = Class.forName(pName, false, classLoader)
                    if (!java.lang.reflect.Modifier.isAbstract(cls.modifiers) &&
                        (CatalogueSource::class.java.isAssignableFrom(cls) || SourceFactory::class.java.isAssignableFrom(cls))) {
                        rawClassField = pName
                        break
                    }
                } catch (_: Throwable) {}
            }
        }

        if (rawClassField.isNullOrEmpty()) {
            throw IllegalStateException("Cannot resolve extension class name for $basePkg in $apkPath")
        }

        val collectedSources = mutableListOf<CatalogueSource>()
        val classTokens = rawClassField.split(";").map { it.trim() }.filter { it.isNotEmpty() }

        for (token in classTokens) {
            val candidates = if (token.startsWith(".")) {
                listOf("$manifestPkg$token", "$basePkg$token").distinct()
            } else {
                listOf(token)
            }
            var loadedClass: Class<*>? = null
            for (cName in candidates) {
                try {
                    loadedClass = Class.forName(cName, false, classLoader)
                    break
                } catch (_: Throwable) {}
            }
            if (loadedClass == null) continue

            try {
                when {
                    SourceFactory::class.java.isAssignableFrom(loadedClass) -> {
                        val factory = loadedClass.getDeclaredConstructor().newInstance() as SourceFactory
                        collectedSources.addAll(factory.createSources().filterIsInstance<CatalogueSource>())
                    }
                    CatalogueSource::class.java.isAssignableFrom(loadedClass) -> {
                        val instance = loadedClass.getDeclaredConstructor().newInstance() as CatalogueSource
                        collectedSources.add(instance)
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Error instantiating $loadedClass for $basePkg: ${e.message}", e)
            }
        }

        if (collectedSources.isEmpty()) {
            throw IllegalStateException("Extension $basePkg ($rawClassField) produced no CatalogueSources")
        }

        allSourcesCache[basePkg] = collectedSources
        return collectedSources
    }

    @Synchronized
    fun getOrLoadSource(pkg: String, hintPath: String? = null): CatalogueSource {
        sourceCache[pkg]?.let { return it }

        val (basePkg, selector) = splitPkgSelector(pkg)
        val sources = loadAllSourcesForPkg(basePkg, hintPath)

        val chosen: CatalogueSource = if (selector.isNotEmpty()) {
            sources.firstOrNull { it.id.toString() == selector }
                ?: sources.firstOrNull { it.name.equals(selector, ignoreCase = true) }
                ?: sources.firstOrNull { it.lang.equals(selector, ignoreCase = true) }
                ?: sources.firstOrNull { it.name.contains(selector, ignoreCase = true) }
                ?: sources.first()
        } else {
            val pkgLang = if (basePkg.contains(".extension.")) {
                basePkg.substringAfter(".extension.").substringBefore('.').lowercase()
            } else {
                val parts = basePkg.split('.')
                if (parts.size >= 5) parts[4].lowercase() else ""
            }
            val matching = if (pkgLang.isNotEmpty() && pkgLang != "all") {
                sources.firstOrNull { it.lang.equals(pkgLang, ignoreCase = true) }
            } else null
            matching
                ?: sources.firstOrNull { it.lang.equals("en", ignoreCase = true) }
                ?: sources.firstOrNull { it.lang.equals("all", ignoreCase = true) }
                ?: sources.first()
        }

        sourceCache[pkg] = chosen
        return chosen
    }

    fun removeSource(pkg: String) {
        val (basePkg, _) = splitPkgSelector(pkg)
        sourceCache.keys.filter { it == basePkg || it.startsWith("$basePkg@") }.forEach { sourceCache.remove(it) }
        allSourcesCache.remove(basePkg)
        val prefix = "$basePkg:"
        mangaCache.keys.filter { it.startsWith(prefix) }.forEach { mangaCache.remove(it) }
        chapterCache.keys.filter { it.startsWith(prefix) }.forEach { chapterCache.remove(it) }

        val safePkg = basePkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
        if (safePkg.isNotEmpty()) {
            try {
                val dexDir = File(context.codeCacheDir, "shiori_dex_readonly")
                if (dexDir.exists()) {
                    dexDir.listFiles()?.forEach { f ->
                        if (f.name.startsWith("${safePkg}_")) {
                            try {
                                f.setWritable(true)
                                f.delete()
                            } catch (_: Throwable) {}
                        }
                    }
                }
                val libsRoot = File(context.codeCacheDir, "shiori_native_libs")
                if (libsRoot.exists()) {
                    libsRoot.listFiles()?.forEach { dir ->
                        if (dir.name.startsWith("${safePkg}_")) {
                            try {
                                dir.walkBottomUp().forEach { child ->
                                    try { child.setWritable(true) } catch (_: Throwable) {}
                                    try { child.delete() } catch (_: Throwable) {}
                                }
                            } catch (_: Throwable) {}
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
    }

    fun clearCache() {
        sourceCache.clear()
        allSourcesCache.clear()
        mangaCache.clear()
        chapterCache.clear()
        pageCache.clear()
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

    private fun getCookiesForUrl(url: String): String {
        if (url.isBlank()) return ""
        return try {
            CookieManager.getInstance().getCookie(url)?.trim().orEmpty()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun hasCustomImagePipeline(source: CatalogueSource): Boolean {
        if (source !is HttpSource) return false
        val baseUrl = try { source.baseUrl } catch (_: Throwable) { "" }
        if (getCookiesForUrl(baseUrl).isNotEmpty()) return true

        return customImagePipelineSupport.getOrPut(source.javaClass) {
            try {
                val overridesImageReq = source.javaClass.methods.any {
                    (it.name == "imageRequest" || it.name == "fetchImage" || it.name == "getImage") &&
                        it.declaringClass != HttpSource::class.java
                }
                if (overridesImageReq) return@getOrPut true

                val interceptors = source.client.interceptors
                val hasCustomInterceptor = interceptors.any { interceptor ->
                    interceptor !is UncaughtExceptionInterceptor &&
                        interceptor !is UserAgentInterceptor &&
                        interceptor !is CloudflareInterceptor &&
                        interceptor !is RateLimitInterceptor &&
                        interceptor.javaClass.name != "okhttp3.CompressionInterceptor" &&
                        !interceptor.javaClass.name.startsWith("okhttp3.brotli.")
                }
                hasCustomInterceptor || source.client.networkInterceptors.isNotEmpty()
            } catch (_: Throwable) {
                false
            }
        }
    }

    private fun extractHeadersMap(source: CatalogueSource?, targetUrl: String = ""): Map<String, String> {
        if (source !is HttpSource) return emptyMap()
        val result = linkedMapOf<String, String>()
        try {
            val h = source.headers
            for (i in 0 until h.size) {
                result[h.name(i)] = h.value(i)
            }
        } catch (_: Throwable) {}

        val base = try { source.baseUrl } catch (_: Throwable) { "" }
        if (!result.keys.any { it.equals("Referer", ignoreCase = true) } && base.startsWith("http")) {
            result["Referer"] = if (base.endsWith("/")) base else "$base/"
        }
        if (!result.keys.any { it.equals("User-Agent", ignoreCase = true) }) {
            try {
                result["User-Agent"] = source.network.defaultUserAgentProvider()
            } catch (_: Throwable) {}
        }
        val cookieUrl = targetUrl.ifBlank { base }
        val cookies = getCookiesForUrl(cookieUrl).ifBlank { getCookiesForUrl(base) }
        if (cookies.isNotEmpty() && !result.keys.any { it.equals("Cookie", ignoreCase = true) }) {
            result["Cookie"] = cookies
        }
        return result
    }

    fun getSourceHeaders(pkg: String, hintPath: String? = null): Map<String, Any?> {
        return try {
            val src = getOrLoadSource(pkg, hintPath)
            val baseUrl = if (src is HttpSource) src.baseUrl else ""
            val headers = extractHeadersMap(src, baseUrl)
            val referer = headers.entries.firstOrNull { it.key.equals("Referer", ignoreCase = true) }?.value ?: baseUrl
            mapOf(
                "baseUrl" to baseUrl,
                "referer" to referer,
                "headers" to headers,
                "nativeImages" to hasCustomImagePipeline(src),
                "supportsLatest" to src.supportsLatest
            )
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    private fun resolveSourceUrl(raw: String, source: CatalogueSource?): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) return trimmed
        if (trimmed.startsWith("//")) return "https:$trimmed"
        if (source is HttpSource) {
            val baseHttp = try { source.baseUrl.toHttpUrlOrNull() } catch (_: Throwable) { null }
            val resolved = try { baseHttp?.resolve(trimmed)?.toString() } catch (_: Throwable) { null }
            if (!resolved.isNullOrEmpty()) return resolved
            val base = source.baseUrl.trimEnd('/')
            if (base.startsWith("http")) {
                return "$base/${trimmed.trimStart('/')}"
            }
        }
        return trimmed
    }

    private suspend fun loadSingleDetailsInternal(
        pkg: String,
        source: CatalogueSource,
        sManga: SManga
    ): SManga? {
        if (supportsMangaUpdate(source) && source is HttpSource) {
            try {
                return fetchViaMangaUpdate(pkg, source, sManga, emptyList(), true, false).manga
            } catch (_: Throwable) {}
        }
        try {
            return try {
                source.getMangaDetails(sManga)
            } catch (_: NoSuchMethodError) {
                source.fetchMangaDetails(sManga).toBlocking().first()
            } catch (_: AbstractMethodError) {
                source.fetchMangaDetails(sManga).toBlocking().first()
            }
        } catch (_: Throwable) {
            try {
                return source.fetchMangaDetails(sManga).toBlocking().first()
            } catch (_: Throwable) {}
        }
        if (!supportsMangaUpdate(source) && source is HttpSource) {
            try {
                return fetchViaMangaUpdate(pkg, source, sManga, emptyList(), true, false).manga
            } catch (_: Throwable) {}
        }
        return null
    }

    private suspend fun enrichMissingThumbnails(
        pkg: String,
        source: CatalogueSource,
        mangas: List<SManga>
    ) {
        val (basePkg, _) = splitPkgSelector(pkg)
        val missing = mutableListOf<SManga>()
        for (m in mangas) {
            if (m.thumbnail_url.isNullOrBlank() && m.url.isNotBlank()) {
                val cached = mangaCache["$pkg:${m.url}"] ?: mangaCache["$basePkg:${m.url}"]
                if (cached != null && !cached.thumbnail_url.isNullOrBlank()) {
                    m.thumbnail_url = cached.thumbnail_url
                } else {
                    missing.add(m)
                }
            }
        }
        if (missing.isEmpty()) return

        val sem = Semaphore(4)
        coroutineScope {
            missing.take(8).map { m ->
                async {
                    sem.withPermit {
                        withTimeoutOrNull(3500L) {
                            val details = loadSingleDetailsInternal(pkg, source, m)
                            if (details != null && !details.thumbnail_url.isNullOrBlank()) {
                                m.thumbnail_url = details.thumbnail_url
                                if (details.url.isEmpty()) details.url = m.url
                                if (details.title.isEmpty()) details.title = m.title
                                mangaCache["$pkg:${m.url}"] = details
                                mangaCache["$basePkg:${m.url}"] = details
                            }
                        }
                    }
                }
            }.awaitAll()
        }
    }

    private fun filterItemsByType(items: List<Map<String, Any?>>, type: String?): List<Map<String, Any?>> {
        if (items.isEmpty() || type.isNullOrBlank() || type.equals("all", ignoreCase = true)) {
            return items
        }
        val target = type.lowercase()
        val filtered = items.filter { item ->
            val genre = (item["genre"] as? String)?.lowercase() ?: ""
            val title = (item["title"] as? String)?.lowercase() ?: ""
            val url = (item["url"] as? String)?.lowercase() ?: ""
            val combined = "$genre $title $url"
            when (target) {
                "manhwa" -> combined.contains("manhwa") || combined.contains("webtoon")
                "manhua" -> combined.contains("manhua")
                else -> !combined.contains("manhwa") && !combined.contains("manhua")
            }
        }
        return filtered.ifEmpty { items }
    }

    suspend fun fetchPopularManga(
        pkg: String,
        page: Int,
        type: String? = null,
        hintPath: String? = null
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val (basePkg, _) = splitPkgSelector(pkg)
        val source = getOrLoadSource(pkg, hintPath)

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
                        mangaCache["$basePkg:${m.url}"] = m
                    }
                    enrichMissingThumbnails(pkg, source, filterSearchPage.mangas)
                    return@withContext filterSearchPage.mangas.map { sMangaToMap(it, source, pkg) }
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

        val list = mangasPage?.mangas ?: emptyList()
        list.forEach { m ->
            mangaCache["$pkg:${m.url}"] = m
            mangaCache["$basePkg:${m.url}"] = m
        }
        enrichMissingThumbnails(pkg, source, list)

        val items = list.map { sMangaToMap(it, source, pkg) }
        filterItemsByType(items, type)
    }

    suspend fun fetchLatestUpdates(
        pkg: String,
        page: Int,
        type: String? = null,
        hintPath: String? = null
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val (basePkg, _) = splitPkgSelector(pkg)
        val source = getOrLoadSource(pkg, hintPath)

        if (!source.supportsLatest) {
            return@withContext fetchPopularManga(pkg, page, type, hintPath)
        }

        if (!type.isNullOrBlank() && !type.equals("all", ignoreCase = true)) {
            try {
                val filters = getSafeFilterList(source)
                applyTypeFilter(filters, type)
                filters.filterIsInstance<Filter.Sort>().forEach { sort ->
                    val values = sort.values
                    for (i in values.indices) {
                        val v = values[i].lowercase()
                        if (v.contains("latest") || v.contains("update") || v.contains("new") || v.contains("recent")) {
                            sort.state = Filter.Sort.Selection(i, false)
                            break
                        }
                    }
                }
                val filterSearchPage = try {
                    source.getSearchManga(page, "", filters)
                } catch (_: NoSuchMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                } catch (_: AbstractMethodError) {
                    source.fetchSearchManga(page, "", filters).toBlocking().first()
                }
                if (filterSearchPage.mangas.isNotEmpty()) {
                    filterSearchPage.mangas.forEach { m ->
                        mangaCache["$pkg:${m.url}"] = m
                        mangaCache["$basePkg:${m.url}"] = m
                    }
                    enrichMissingThumbnails(pkg, source, filterSearchPage.mangas)
                    return@withContext filterSearchPage.mangas.map { sMangaToMap(it, source, pkg) }
                }
            } catch (_: Throwable) {}
        }

        var lastError: Throwable? = null
        val mangasPage = try {
            try {
                source.getLatestUpdates(page)
            } catch (_: NoSuchMethodError) {
                source.fetchLatestUpdates(page).toBlocking().first()
            } catch (_: AbstractMethodError) {
                source.fetchLatestUpdates(page).toBlocking().first()
            }
        } catch (e: Throwable) {
            try {
                source.fetchLatestUpdates(page).toBlocking().first()
            } catch (_: Throwable) {
                lastError = e
                Log.w(TAG, "getLatestUpdates failed for $pkg: ${e.message}")
                null
            }
        }

        if (mangasPage == null || mangasPage.mangas.isEmpty()) {
            try {
                return@withContext fetchPopularManga(pkg, page, type, hintPath)
            } catch (_: Throwable) {
                if (lastError != null) throw lastError
                return@withContext emptyList()
            }
        }

        val list = mangasPage.mangas
        list.forEach { m ->
            mangaCache["$pkg:${m.url}"] = m
            mangaCache["$basePkg:${m.url}"] = m
        }
        enrichMissingThumbnails(pkg, source, list)

        val items = list.map { sMangaToMap(it, source, pkg) }
        filterItemsByType(items, type)
    }

    suspend fun searchManga(
        pkg: String,
        query: String,
        page: Int,
        type: String? = null,
        hintPath: String? = null
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val (basePkg, _) = splitPkgSelector(pkg)
        val source = getOrLoadSource(pkg, hintPath)
        val trimmed = query.trim()

        if (trimmed.isEmpty()) {
            return@withContext fetchPopularManga(pkg, page, type, hintPath)
        }

        var mangasPage: MangasPage? = null
        var lastSearchError: Throwable? = null

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

        val list = mangasPage?.mangas ?: emptyList()
        list.forEach { m ->
            mangaCache["$pkg:${m.url}"] = m
            mangaCache["$basePkg:${m.url}"] = m
        }
        enrichMissingThumbnails(pkg, source, list)

        list.map { sMangaToMap(it, source, pkg) }
    }

    private fun computeLegacySlugUrl(url: String): String? {
        return if (url.startsWith("/comic/")) {
            url.removePrefix("/comic/").trim('/')
        } else if (url.contains("/comic/")) {
            url.substringAfterLast("/comic/").trim('/')
        } else {
            null
        }
    }

    suspend fun fetchMangaDetails(pkg: String, url: String, title: String?, hintPath: String? = null): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val (basePkg, _) = splitPkgSelector(pkg)
            val source = getOrLoadSource(pkg, hintPath)
            val legacySlug = computeLegacySlugUrl(url)
            val useLegacyFirst = basePkg.contains("comick", ignoreCase = true) && !legacySlug.isNullOrEmpty()
            val primaryUrl = if (useLegacyFirst) legacySlug!! else url

            val sManga = mangaCache["$pkg:$url"]
                ?: mangaCache["$basePkg:$url"]
                ?: (if (legacySlug != null) mangaCache["$pkg:$legacySlug"] ?: mangaCache["$basePkg:$legacySlug"] else null)
                ?: SManga.create().apply {
                    this.url = primaryUrl
                    if (!title.isNullOrEmpty()) this.title = title
                }

            suspend fun tryResolveDetails(targetManga: SManga): Pair<SManga?, Throwable?> {
                var resolved: SManga? = null
                var err: Throwable? = null

                if (supportsMangaUpdate(source)) {
                    try {
                        resolved = fetchViaMangaUpdate(pkg, source as HttpSource, targetManga, emptyList(), true, false).manga
                    } catch (e: Throwable) {
                        err = e
                        Log.w(TAG, "fetchViaMangaUpdate failed for details of ${targetManga.url} ($pkg): ${e.message}")
                    }
                }

                if (resolved == null) {
                    try {
                        resolved = try {
                            source.getMangaDetails(targetManga)
                        } catch (_: NoSuchMethodError) {
                            source.fetchMangaDetails(targetManga).toBlocking().first()
                        } catch (_: AbstractMethodError) {
                            source.fetchMangaDetails(targetManga).toBlocking().first()
                        }
                    } catch (e: Throwable) {
                        try {
                            resolved = source.fetchMangaDetails(targetManga).toBlocking().first()
                        } catch (_: Throwable) {
                            if (err == null) err = e
                            Log.w(TAG, "source.getMangaDetails failed for ${targetManga.url} ($pkg): ${e.message}")
                        }
                    }
                }

                if (resolved == null && !supportsMangaUpdate(source) && source is HttpSource) {
                    try {
                        resolved = fetchViaMangaUpdate(pkg, source, targetManga, emptyList(), true, false).manga
                    } catch (_: Throwable) {}
                }

                return resolved to err
            }

            var (details, lastError) = tryResolveDetails(sManga)

            if (details == null && source is HttpSource) {
                val relativeUrl = if (url.startsWith("http")) source.getUrlWithoutDomain(url) else null
                val altUrl = when {
                    !relativeUrl.isNullOrEmpty() && relativeUrl != sManga.url -> relativeUrl
                    !legacySlug.isNullOrEmpty() && legacySlug != sManga.url -> legacySlug
                    else -> null
                }
                if (altUrl != null) {
                    val altManga = SManga.create().apply {
                        this.url = altUrl
                        if (!title.isNullOrEmpty()) this.title = title
                        this.thumbnail_url = sManga.thumbnail_url
                    }
                    val (altDetails, _) = tryResolveDetails(altManga)
                    if (altDetails != null) {
                        details = altDetails
                    }
                }
            }

            if (details == null) {
                throw (lastError ?: IllegalStateException("Failed to load details for $url"))
            }

            if (details.url.isEmpty()) details.url = sManga.url.ifEmpty { url }
            if (details.title.isEmpty() && !title.isNullOrEmpty()) details.title = title
            if (details.thumbnail_url.isNullOrEmpty() && !sManga.thumbnail_url.isNullOrEmpty()) {
                details.thumbnail_url = sManga.thumbnail_url
            }
            if (details.memo == null && sManga.memo != null) {
                details.memo = sManga.memo
            }
            mangaCache["$pkg:$url"] = details
            mangaCache["$basePkg:$url"] = details
            mangaCache["$pkg:${details.url}"] = details
            sMangaToMap(details, source, pkg)
        }

    suspend fun fetchChapterList(pkg: String, url: String, title: String?, hintPath: String? = null): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val (basePkg, _) = splitPkgSelector(pkg)
            val source = getOrLoadSource(pkg, hintPath)
            val legacySlug = computeLegacySlugUrl(url)
            val useLegacyFirst = basePkg.contains("comick", ignoreCase = true) && !legacySlug.isNullOrEmpty()
            val primaryUrl = if (useLegacyFirst) legacySlug!! else url

            val sManga = mangaCache["$pkg:$url"]
                ?: mangaCache["$basePkg:$url"]
                ?: (if (legacySlug != null) mangaCache["$pkg:$legacySlug"] ?: mangaCache["$basePkg:$legacySlug"] else null)
                ?: SManga.create().apply {
                    this.url = primaryUrl
                    if (!title.isNullOrEmpty()) this.title = title
                }

            suspend fun tryResolveChapters(targetManga: SManga): Pair<List<SChapter>?, Throwable?> {
                var resolved: List<SChapter>? = null
                var err: Throwable? = null

                if (supportsMangaUpdate(source)) {
                    try {
                        resolved = fetchViaMangaUpdate(pkg, source as HttpSource, targetManga, emptyList(), false, true).chapters
                    } catch (e: Throwable) {
                        err = e
                        Log.w(TAG, "fetchViaMangaUpdate failed for chapters of ${targetManga.url} ($pkg): ${e.message}")
                    }
                }

                if (resolved == null) {
                    try {
                        resolved = try {
                            source.getChapterList(targetManga)
                        } catch (_: NoSuchMethodError) {
                            source.fetchChapterList(targetManga).toBlocking().first()
                        } catch (_: AbstractMethodError) {
                            source.fetchChapterList(targetManga).toBlocking().first()
                        }
                    } catch (e: Throwable) {
                        try {
                            resolved = source.fetchChapterList(targetManga).toBlocking().first()
                        } catch (_: Throwable) {
                            if (err == null) err = e
                            Log.w(TAG, "source.getChapterList failed for ${targetManga.url} ($pkg): ${e.message}")
                        }
                    }
                }

                if (resolved == null && !supportsMangaUpdate(source) && source is HttpSource) {
                    try {
                        resolved = fetchViaMangaUpdate(pkg, source, targetManga, emptyList(), false, true).chapters
                    } catch (_: Throwable) {}
                }

                return resolved to err
            }

            var (chapters, lastError) = tryResolveChapters(sManga)

            if (chapters == null && source is HttpSource) {
                val relativeUrl = if (url.startsWith("http")) source.getUrlWithoutDomain(url) else null
                val altUrl = when {
                    !relativeUrl.isNullOrEmpty() && relativeUrl != sManga.url -> relativeUrl
                    !legacySlug.isNullOrEmpty() && legacySlug != sManga.url -> legacySlug
                    else -> null
                }
                if (altUrl != null) {
                    val altManga = SManga.create().apply {
                        this.url = altUrl
                        if (!title.isNullOrEmpty()) this.title = title
                    }
                    val (altChapters, _) = tryResolveChapters(altManga)
                    if (altChapters != null) {
                        chapters = altChapters
                    }
                }
            }

            if (chapters == null) {
                throw (lastError ?: IllegalStateException("Failed to load chapters for $url"))
            }

            val mangaSlug = sManga.memo?.get("slug")?.toString()?.trim('"')
            chapters.forEach { c ->
                if (source is HttpSource && c.chapter_number < 0f) {
                    try {
                        source.prepareNewChapter(c, sManga)
                    } catch (_: Throwable) {}
                }
                if (c.memo == null && !mangaSlug.isNullOrEmpty()) {
                    c.memo = kotlinx.serialization.json.buildJsonObject {
                        put("mangaSlug", kotlinx.serialization.json.JsonPrimitive(mangaSlug))
                        put("slug", kotlinx.serialization.json.JsonPrimitive(mangaSlug))
                    }
                }
                chapterCache["$pkg:${c.url}"] = c
                chapterCache["$basePkg:${c.url}"] = c
                if (source is HttpSource) {
                    val rel = source.getUrlWithoutDomain(c.url)
                    chapterCache["$pkg:$rel"] = c
                    chapterCache["$basePkg:$rel"] = c
                }
            }
            chapters.map { sChapterToMap(it) }
        }

    suspend fun fetchPageList(pkg: String, chapterUrl: String, hintPath: String? = null): List<String> =
        withContext(Dispatchers.IO) {
            val (basePkg, _) = splitPkgSelector(pkg)
            val source = getOrLoadSource(pkg, hintPath)
            val sChapter = chapterCache["$pkg:$chapterUrl"]
                ?: chapterCache["$basePkg:$chapterUrl"]
                ?: (if (source is HttpSource) {
                    val rel = source.getUrlWithoutDomain(chapterUrl)
                    chapterCache["$pkg:$rel"] ?: chapterCache["$basePkg:$rel"]
                } else null)
                ?: SChapter.create().apply {
                    this.url = if (source is HttpSource && chapterUrl.startsWith("http")) {
                        source.getUrlWithoutDomain(chapterUrl)
                    } else {
                        chapterUrl
                    }
                }

            val pages = try {
                try {
                    source.getPageList(sChapter)
                } catch (_: NoSuchMethodError) {
                    source.fetchPageList(sChapter).toBlocking().first()
                } catch (_: AbstractMethodError) {
                    source.fetchPageList(sChapter).toBlocking().first()
                }
            } catch (e: Throwable) {
                try {
                    source.fetchPageList(sChapter).toBlocking().first()
                } catch (_: Throwable) {
                    if (sChapter.url != chapterUrl) {
                        val altChapter = SChapter.create().apply { this.url = chapterUrl }
                        try {
                            source.getPageList(altChapter)
                        } catch (_: Throwable) {
                            source.fetchPageList(altChapter).toBlocking().first()
                        }
                    } else {
                        throw e
                    }
                }
            }

            if (pageCache.size > 600) {
                pageCache.clear()
            }

            val sem = Semaphore(4)
            coroutineScope {
                pages.mapIndexed { idx, page ->
                    async {
                        sem.withPermit {
                            var imgUrl = page.imageUrl
                            if (imgUrl.isNullOrEmpty() && page.url.isNotEmpty()) {
                                for (attempt in 0..1) {
                                    try {
                                        imgUrl = try {
                                            source.getImageUrl(page)
                                        } catch (_: NoSuchMethodError) {
                                            source.fetchImageUrl(page).toBlocking().first()
                                        } catch (_: AbstractMethodError) {
                                            source.fetchImageUrl(page).toBlocking().first()
                                        }
                                        if (!imgUrl.isNullOrEmpty()) break
                                    } catch (e: Throwable) {
                                        if (attempt == 1) {
                                            Log.w(TAG, "Failed to fetch image URL for page ${page.index}: ${e.message}")
                                        }
                                    }
                                }
                            }

                            var finalUrl = resolveSourceUrl(imgUrl ?: "", source)
                            if (finalUrl.isEmpty() && page.url.isNotEmpty()) {
                                finalUrl = resolveSourceUrl(page.url, source)
                            }
                            if (source is HttpSource && finalUrl.isNotEmpty() && !imgUrl.isNullOrEmpty()) {
                                try {
                                    val resolvedPage = Page(page.index, page.url, finalUrl)
                                    val reqUrl = source.imageRequest(resolvedPage).url.toString()
                                    if (reqUrl.startsWith("http://") || reqUrl.startsWith("https://")) {
                                        finalUrl = reqUrl
                                    }
                                    pageCache[finalUrl] = Page(page.index, page.url, finalUrl)
                                } catch (_: Throwable) {
                                    pageCache[finalUrl] = Page(page.index, page.url, finalUrl)
                                }
                            } else if (finalUrl.isNotEmpty()) {
                                pageCache[finalUrl] = Page(idx, page.url, imgUrl)
                            }
                            finalUrl
                        }
                    }
                }.awaitAll()
            }
        }

    suspend fun fetchImageBytes(
        pkg: String,
        imageUrl: String,
        pageUrl: String? = null,
        hintPath: String? = null
    ): ByteArray = withContext(Dispatchers.IO) {
        val source = getOrLoadSource(pkg, hintPath)
        if (source !is HttpSource) {
            throw IllegalStateException("Source $pkg is not an HttpSource")
        }

        var cachedPage = pageCache[imageUrl]
        var targetImgUrl = imageUrl

        if (cachedPage != null && cachedPage.imageUrl.isNullOrEmpty() && cachedPage.url.isNotEmpty()) {
            try {
                val freshlyResolved = try {
                    source.getImageUrl(cachedPage)
                } catch (_: NoSuchMethodError) {
                    source.fetchImageUrl(cachedPage).toBlocking().first()
                } catch (_: AbstractMethodError) {
                    source.fetchImageUrl(cachedPage).toBlocking().first()
                }
                if (freshlyResolved.isNotBlank()) {
                    targetImgUrl = resolveSourceUrl(freshlyResolved, source)
                    cachedPage = Page(cachedPage.index, cachedPage.url, targetImgUrl)
                    pageCache[imageUrl] = cachedPage
                    pageCache[targetImgUrl] = cachedPage
                }
            } catch (_: Throwable) {}
        }

        val isCoverOrDirect = pageUrl.isNullOrBlank() || targetImgUrl.contains("/covers/") || targetImgUrl.contains("uploads.mangadex.org")
        var lastErr: Throwable? = null

        if (isCoverOrDirect) {
            try {
                val req = try {
                    GET(targetImgUrl, source.headers)
                } catch (_: Throwable) {
                    Request.Builder().url(targetImgUrl).headers(source.headers).build()
                }
                source.client.newCall(req).execute().use { res ->
                    if (res.isSuccessful) {
                        val bytes = res.body?.bytes()
                        if (bytes != null && bytes.isNotEmpty()) {
                            return@withContext bytes
                        }
                    } else {
                        lastErr = IllegalStateException("HTTP ${res.code} loading direct image from ${source.name}")
                    }
                }
            } catch (e: Throwable) {
                lastErr = e
            }
        } else {
            val page = cachedPage ?: Page(0, pageUrl ?: "", targetImgUrl)
            try {
                val response = try {
                    source.getImage(page)
                } catch (_: NoSuchMethodError) {
                    source.fetchImage(page).toBlocking().first()
                } catch (_: AbstractMethodError) {
                    source.fetchImage(page).toBlocking().first()
                }
                response.use { res ->
                    if (res.isSuccessful) {
                        val bytes = res.body?.bytes()
                        if (bytes != null && bytes.isNotEmpty()) {
                            return@withContext bytes
                        }
                    } else {
                        lastErr = IllegalStateException("HTTP ${res.code} loading image from ${source.name}")
                    }
                }
            } catch (e: Throwable) {
                lastErr = e
            }

            try {
                val req = try {
                    GET(targetImgUrl, source.headers)
                } catch (_: Throwable) {
                    Request.Builder().url(targetImgUrl).headers(source.headers).build()
                }
                source.client.newCall(req).execute().use { res ->
                    if (res.isSuccessful) {
                        val bytes = res.body?.bytes()
                        if (bytes != null && bytes.isNotEmpty()) {
                            return@withContext bytes
                        }
                    } else if (lastErr == null) {
                        lastErr = IllegalStateException("HTTP ${res.code} loading image")
                    }
                }
            } catch (e: Throwable) {
                if (lastErr == null) lastErr = e
            }
        }

        throw (lastErr ?: IllegalStateException("Empty image response for $targetImgUrl"))
    }

    private fun sMangaToMap(sManga: SManga, source: CatalogueSource? = null, pkg: String = ""): Map<String, Any?> {
        val thumb = resolveSourceUrl(sManga.thumbnail_url ?: "", source)
        val headers = extractHeadersMap(source, thumb)
        val referer = headers.entries.firstOrNull { it.key.equals("Referer", ignoreCase = true) }?.value
            ?: (if (source is HttpSource) source.baseUrl else "")
        val nativeImages = source != null && hasCustomImagePipeline(source)

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
            "headers" to headers,
            "nativeImages" to nativeImages,
            "pkg" to pkg,
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
