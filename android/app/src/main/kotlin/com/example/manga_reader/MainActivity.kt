package com.example.manga_reader

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

class MainActivity : FlutterActivity() {
    private val INSTALLER_CHANNEL = "com.example.manga_reader/installer"
    private val EXTENSIONS_CHANNEL = "com.example.manga_reader/extensions"
    private val REQUEST_WEBVIEW = 9401
    private val REQUEST_UNKNOWN_SOURCES = 9403
    private val REQUEST_ACTION_VIEW_INSTALL = 9404

    private var pendingWebViewResult: MethodChannel.Result? = null
    private var pendingUnknownSourcesDeferred: CompletableDeferred<Boolean>? = null
    private var pendingActionViewInstallDeferred: CompletableDeferred<Unit>? = null
    private var installerMethodChannel: MethodChannel? = null

    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val extensionManager by lazy { TachiyomiExtensionManager(applicationContext) }

    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            val pkg = intent.data?.schemeSpecificPart ?: return
            val isExtPkg = pkg.contains("tachiyomi.extension") ||
                pkg.startsWith("eu.kanade.tachiyomi") ||
                ExtensionInstallCoordinator.hasActiveSessionForPkg(pkg)
            if (isExtPkg) {
                extensionManager.removeSource(pkg)
                if (action == Intent.ACTION_PACKAGE_ADDED || action == Intent.ACTION_PACKAGE_REPLACED) {
                    ExtensionInstallCoordinator.onPackageInstalledBroadcast(applicationContext, pkg)
                }
                installerMethodChannel?.invokeMethod(
                    "onPackagesChanged",
                    mapOf("pkg" to pkg, "action" to action)
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val pkgFilter = IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addDataScheme("package")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(packageChangeReceiver, pkgFilter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(packageChangeReceiver, pkgFilter)
            }
        } catch (e: Throwable) {
            android.util.Log.w("MainActivity", "Failed to register package receiver: ${e.message}")
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(packageChangeReceiver) } catch (_: Throwable) {}
        pendingUnknownSourcesDeferred?.complete(false)
        pendingUnknownSourcesDeferred = null
        pendingActionViewInstallDeferred?.complete(Unit)
        pendingActionViewInstallDeferred = null
        super.onDestroy()
    }

    private suspend fun requestUnknownSourcesPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            return true
        }
        return withContext(Dispatchers.Main) {
            pendingUnknownSourcesDeferred?.complete(packageManager.canRequestPackageInstalls())
            val deferred = CompletableDeferred<Boolean>()
            pendingUnknownSourcesDeferred = deferred
            try {
                val permIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
                @Suppress("DEPRECATION")
                startActivityForResult(permIntent, REQUEST_UNKNOWN_SOURCES)
            } catch (e: Throwable) {
                pendingUnknownSourcesDeferred = null
                try {
                    val fallbackIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(fallbackIntent)
                } catch (_: Throwable) {}
                return@withContext false
            }
            withTimeoutOrNull(120_000L) { deferred.await() } ?: packageManager.canRequestPackageInstalls()
        }
    }

    private suspend fun installViaPackageInstallerAndAwait(
        apkFile: File,
        archivePkg: String,
        archiveVersionCode: Long
    ): InstallOutcome = withContext(Dispatchers.IO) {
        val packageInstaller = applicationContext.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            if (archivePkg.isNotEmpty()) {
                setAppPackageName(archivePkg)
            }
            if (apkFile.length() > 0L) {
                setSize(apkFile.length())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                setRequestUpdateOwnership(true)
            }
        }

        val sessionId = packageInstaller.createSession(params)
        val deferred = ExtensionInstallCoordinator.registerSession(
            sessionId = sessionId,
            targetPkg = archivePkg,
            expectedVersionCode = archiveVersionCode
        )

        try {
            packageInstaller.openSession(sessionId).use { session ->
                apkFile.inputStream().use { input ->
                    session.openWrite("extension.apk", 0, apkFile.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }

                val callbackIntent = Intent(applicationContext, ExtensionInstallActivity::class.java).apply {
                    putExtra(ExtensionInstallCoordinator.EXTRA_SHIORI_SESSION_ID, sessionId)
                    putExtra(ExtensionInstallCoordinator.EXTRA_SHIORI_TARGET_PKG, archivePkg)
                }
                val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pendingOptions: Bundle? = when {
                    Build.VERSION.SDK_INT >= 36 -> {
                        ActivityOptions.makeBasic()
                            .setPendingIntentCreatorBackgroundActivityStartMode(
                                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                            )
                            .toBundle()
                    }
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                        @Suppress("DEPRECATION")
                        ActivityOptions.makeBasic()
                            .setPendingIntentCreatorBackgroundActivityStartMode(
                                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                            )
                            .toBundle()
                    }
                    else -> null
                }

                val pendingIntent = if (pendingOptions != null) {
                    PendingIntent.getActivity(
                        applicationContext,
                        sessionId,
                        callbackIntent,
                        pendingFlags,
                        pendingOptions
                    )
                } else {
                    PendingIntent.getActivity(
                        applicationContext,
                        sessionId,
                        callbackIntent,
                        pendingFlags
                    )
                }
                session.commit(pendingIntent.intentSender)
            }
        } catch (e: Throwable) {
            ExtensionInstallCoordinator.removeSession(sessionId)
            try {
                packageInstaller.abandonSession(sessionId)
            } catch (_: Throwable) {}
            throw e
        }

        val outcome = withTimeoutOrNull(120_000L) {
            deferred.await()
        }
        if (outcome != null) {
            return@withContext outcome
        }

        ExtensionInstallCoordinator.removeSession(sessionId)
        val installedCode = ExtensionInstallCoordinator.getInstalledVersionCode(applicationContext, archivePkg)
        if (installedCode > 0L && (archiveVersionCode <= 0L || installedCode >= archiveVersionCode)) {
            InstallOutcome.Success
        } else {
            InstallOutcome.Failure("INSTALL_TIMEOUT", "Timed out waiting for Android package installer.")
        }
    }

    private suspend fun installViaActionViewAndAwait(
        apkFile: File,
        archivePkg: String,
        archiveVersionCode: Long
    ): InstallOutcome {
        withContext(Dispatchers.Main) {
            val uri = FileProvider.getUriForFile(
                this@MainActivity,
                "${applicationContext.packageName}.fileprovider",
                apkFile
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            pendingActionViewInstallDeferred?.complete(Unit)
            val waitDeferred = CompletableDeferred<Unit>()
            pendingActionViewInstallDeferred = waitDeferred
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(intent, REQUEST_ACTION_VIEW_INSTALL)
                withTimeoutOrNull(120_000L) { waitDeferred.await() }
            } catch (e: Throwable) {
                pendingActionViewInstallDeferred = null
                throw e
            }
        }

        // Allow PackageManager brief moment to commit after installer UI closes
        for (i in 0 until 8) {
            val installedCode = ExtensionInstallCoordinator.getInstalledVersionCode(applicationContext, archivePkg)
            if (installedCode > 0L && (archiveVersionCode <= 0L || installedCode >= archiveVersionCode)) {
                return InstallOutcome.Success
            }
            delay(250L)
        }
        return InstallOutcome.Failure("INSTALL_CANCELLED", "Update cancelled.")
    }

    private fun cleanupPrivateApkCopies(pkg: String, exceptCanonicalPath: String? = null) {
        val basePkg = pkg.substringBefore('@').trim()
        if (basePkg.isEmpty()) return
        val clean = basePkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
        listOfNotNull(
            File(filesDir, "shiori_extensions"),
            File(cacheDir, "shiori_extensions"),
            File(codeCacheDir, "shiori_extensions"),
            externalCacheDir?.let { File(it, "shiori_extensions") },
            System.getProperty("java.io.tmpdir")?.let { File(it, "shiori_extensions") }
        ).forEach { dir ->
            if (dir.exists()) {
                listOf(File(dir, "$clean.apk"), File(dir, "$basePkg.apk")).forEach { f ->
                    try {
                        if (f.exists() && (exceptCanonicalPath == null || f.canonicalPath != exceptCanonicalPath)) {
                            f.setWritable(true)
                            f.delete()
                        }
                    } catch (_: Throwable) {}
                }
            }
        }
    }

    private fun extractErrorMessage(e: Throwable): String {
        android.util.Log.e("MainActivity", "Extension execution error: ${e.message}", e)
        var cause: Throwable? = e
        while (cause is java.lang.reflect.InvocationTargetException && cause.targetException != null) {
            cause = cause.targetException
        }
        return cause?.message ?: cause?.toString() ?: e.toString()
    }

    private fun getAllExtensionPackages(): List<String> {
        return extensionManager.getInstalledExtensionsDetails()
            .mapNotNull { it["pkg"] as? String }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Installer & package channel
        val installerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
        installerMethodChannel = installerChannel
        installerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("filePath")
                    val expectedFingerprint = call.argument<String>("expectedFingerprint")?.trim()?.lowercase()
                    if (path == null) {
                        result.error("INVALID_ARG", "Path is null", null)
                        return@setMethodCallHandler
                    }
                    mainScope.launch {
                        try {
                            val file = File(path)
                            if (!file.exists() || file.length() == 0L) {
                                result.error("FILE_NOT_FOUND", "APK file does not exist at $path", null)
                                return@launch
                            }

                            if (!expectedFingerprint.isNullOrEmpty()) {
                                val actualFingerprint = withContext(Dispatchers.IO) {
                                    extensionManager.getApkSignatureSha256(file.absolutePath)?.lowercase()
                                }
                                if (!actualFingerprint.isNullOrEmpty() && actualFingerprint != expectedFingerprint) {
                                    result.error(
                                        "SIGNATURE_MISMATCH",
                                        "APK signing key fingerprint ($actualFingerprint) does not match repo ($expectedFingerprint)",
                                        null
                                    )
                                    return@launch
                                }
                            }

                            val (archivePkg, archiveVersionCode) = withContext(Dispatchers.IO) {
                                try {
                                    val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                        packageManager.getPackageArchiveInfo(
                                            file.absolutePath,
                                            PackageManager.PackageInfoFlags.of(0)
                                        )
                                    } else {
                                        @Suppress("DEPRECATION")
                                        packageManager.getPackageArchiveInfo(file.absolutePath, 0)
                                    }
                                    val pkg = info?.packageName ?: ""
                                    val ver = if (info == null) {
                                        0L
                                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                        info.longVersionCode
                                    } else {
                                        @Suppress("DEPRECATION")
                                        info.versionCode.toLong()
                                    }
                                    pkg to ver
                                } catch (_: Throwable) {
                                    "" to 0L
                                }
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                                val granted = requestUnknownSourcesPermission()
                                if (!granted || !packageManager.canRequestPackageInstalls()) {
                                    result.error(
                                        "PERMISSION_DENIED",
                                        "Please allow 'Install unknown apps' for Shiori to install or update extensions.",
                                        null
                                    )
                                    return@launch
                                }
                            }

                            val outcome: InstallOutcome = try {
                                installViaPackageInstallerAndAwait(file, archivePkg, archiveVersionCode)
                            } catch (piError: Throwable) {
                                android.util.Log.w("MainActivity", "PackageInstaller session fallback to ACTION_VIEW: ${piError.message}")
                                installViaActionViewAndAwait(file, archivePkg, archiveVersionCode)
                            }

                            when (outcome) {
                                is InstallOutcome.Success -> {
                                    if (archivePkg.isNotEmpty()) {
                                        withContext(Dispatchers.IO) {
                                            val osCode = ExtensionInstallCoordinator.getInstalledVersionCode(
                                                applicationContext,
                                                archivePkg
                                            )
                                            if (osCode > 0L && (archiveVersionCode <= 0L || osCode >= archiveVersionCode)) {
                                                // PackageManager now owns the updated APK; purge any private duplicate copies
                                                cleanupPrivateApkCopies(archivePkg)
                                            } else {
                                                // Fallback copy only if OS PackageManager is restricted from listing it
                                                try {
                                                    val destDir = File(filesDir, "shiori_extensions")
                                                    if (!destDir.exists()) destDir.mkdirs()
                                                    val clean = archivePkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
                                                    val destFile = File(destDir, "$clean.apk")
                                                    if (file.canonicalPath != destFile.canonicalPath) {
                                                        if (destFile.exists()) {
                                                            destFile.setWritable(true)
                                                            destFile.delete()
                                                        }
                                                        file.copyTo(destFile, overwrite = true)
                                                    }
                                                    cleanupPrivateApkCopies(archivePkg, exceptCanonicalPath = destFile.canonicalPath)
                                                } catch (_: Throwable) {}
                                            }
                                            extensionManager.removeSource(archivePkg)
                                        }
                                        installerMethodChannel?.invokeMethod(
                                            "onPackagesChanged",
                                            mapOf("pkg" to archivePkg, "action" to "PACKAGE_UPDATED", "status" to "SUCCESS")
                                        )
                                    }
                                    result.success(true)
                                }
                                is InstallOutcome.Failure -> {
                                    result.error(outcome.code, outcome.message, null)
                                }
                            }
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message ?: "Unknown installation error", null)
                        }
                    }
                }
                "getInstalledExtensions" -> {
                    mainScope.launch {
                        try {
                            val details = withContext(Dispatchers.IO) {
                                extensionManager.getInstalledExtensionsDetails()
                            }
                            result.success(details)
                        } catch (e: Exception) {
                            result.error("QUERY_ERROR", e.message ?: "Failed to list extensions", null)
                        }
                    }
                }
                "launchPackage" -> {
                    val pkg = call.argument<String>("packageName")
                    if (pkg != null) {
                        val launchIntent = packageManager.getLaunchIntentForPackage(pkg)
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } else {
                        result.error("INVALID_ARG", "packageName is null", null)
                    }
                }
                "isAppInstalled" -> {
                    val pkg = call.argument<String>("packageName")
                    if (pkg != null) {
                        try {
                            packageManager.getPackageInfo(pkg, 0)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.error("INVALID_ARG", "packageName is null", null)
                    }
                }
                "persistExtensionApk" -> {
                    val pkg = call.argument<String>("packageName") ?: call.argument<String>("pkg") ?: ""
                    val srcPath = call.argument<String>("filePath") ?: call.argument<String>("sourcePath") ?: ""
                    if (pkg.isEmpty() || srcPath.isEmpty()) {
                        result.error("INVALID_ARG", "packageName and filePath required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val srcFile = File(srcPath)
                        if (!srcFile.exists() || srcFile.length() == 0L) {
                            result.error("FILE_NOT_FOUND", "Source APK missing at $srcPath", null)
                            return@setMethodCallHandler
                        }
                        val destDir = File(filesDir, "shiori_extensions")
                        if (!destDir.exists()) destDir.mkdirs()
                        val basePkg = pkg.substringBefore('@').trim()
                        val clean = basePkg.replace(Regex("[^a-zA-Z0-9_.]"), "_")
                        val destFile = File(destDir, "$clean.apk")
                        if (srcFile.canonicalPath != destFile.canonicalPath) {
                            if (destFile.exists()) {
                                destFile.setWritable(true)
                                destFile.delete()
                            }
                            srcFile.copyTo(destFile, overwrite = true)
                        }
                        // Remove stale copies in other temporary directories so the updated APK is authoritative
                        cleanupPrivateApkCopies(basePkg, exceptCanonicalPath = destFile.canonicalPath)
                        extensionManager.removeSource(basePkg)
                        result.success(destFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("PERSIST_ERROR", e.message, null)
                    }
                }
                "uninstallPackage" -> {
                    val pkg = call.argument<String>("packageName")
                    if (pkg != null) {
                        try {
                            extensionManager.removeSource(pkg)
                            cleanupPrivateApkCopies(pkg)
                            val isInstalledAsApp = try {
                                packageManager.getPackageInfo(pkg, 0)
                                true
                            } catch (_: Exception) {
                                false
                            }
                            if (isInstalledAsApp && pkg != packageName) {
                                val uninstallIntent = Intent(Intent.ACTION_DELETE).apply {
                                    data = Uri.parse("package:$pkg")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(uninstallIntent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("UNINSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARG", "packageName is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Native Tachiyomi Extension Execution Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTENSIONS_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openInWebView") {
                val url = call.argument<String>("url") ?: ""
                val title = call.argument<String>("title") ?: ""
                if (url.isNotEmpty()) {
                    try {
                        pendingWebViewResult?.let { prev ->
                            try { prev.success(false) } catch (_: Throwable) {}
                        }
                        pendingWebViewResult = result
                        val intent = Intent(this, WebViewActivity::class.java).apply {
                            putExtra(WebViewActivity.EXTRA_URL, url)
                            putExtra(WebViewActivity.EXTRA_TITLE, title)
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQUEST_WEBVIEW)
                    } catch (e: Exception) {
                        pendingWebViewResult = null
                        result.error("WEBVIEW_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARG", "url is empty", null)
                }
                return@setMethodCallHandler
            }

            val pkg = call.argument<String>("pkg") ?: ""
            val apkPath = call.argument<String>("apkPath")

            if (pkg.isEmpty()) {
                result.error("INVALID_ARG", "pkg must be provided", null)
                return@setMethodCallHandler
            }

            when (call.method) {
                "getSourceBaseUrl" -> {
                    mainScope.launch {
                        try {
                            val baseUrl = kotlinx.coroutines.withContext(Dispatchers.IO) {
                                extensionManager.getSourceBaseUrl(pkg, apkPath)
                            }
                            result.success(baseUrl)
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                }
                "getSourceHeaders" -> {
                    mainScope.launch {
                        try {
                            val info = kotlinx.coroutines.withContext(Dispatchers.IO) {
                                extensionManager.getSourceHeaders(pkg, apkPath)
                            }
                            result.success(info)
                        } catch (e: Throwable) {
                            result.error("HEADERS_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchPopularManga" -> {
                    val page = call.argument<Int>("page") ?: 1
                    val type = call.argument<String>("type")
                    mainScope.launch {
                        try {
                            val items = extensionManager.fetchPopularManga(pkg, page, type, apkPath)
                            result.success(items)
                        } catch (e: Throwable) {
                            result.error("FETCH_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchLatestUpdates" -> {
                    val page = call.argument<Int>("page") ?: 1
                    val type = call.argument<String>("type")
                    mainScope.launch {
                        try {
                            val items = extensionManager.fetchLatestUpdates(pkg, page, type, apkPath)
                            result.success(items)
                        } catch (e: Throwable) {
                            result.error("LATEST_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "searchManga" -> {
                    val query = call.argument<String>("query") ?: ""
                    val page = call.argument<Int>("page") ?: 1
                    val type = call.argument<String>("type")
                    mainScope.launch {
                        try {
                            val items = if (query.trim().isEmpty()) {
                                extensionManager.fetchPopularManga(pkg, page, type, apkPath)
                            } else {
                                extensionManager.searchManga(pkg, query, page, type, apkPath)
                            }
                            result.success(items)
                        } catch (e: Throwable) {
                            result.error("SEARCH_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchMangaDetails" -> {
                    val url = call.argument<String>("url") ?: ""
                    val title = call.argument<String>("title")
                    mainScope.launch {
                        try {
                            val details = extensionManager.fetchMangaDetails(pkg, url, title, apkPath)
                            result.success(details)
                        } catch (e: Throwable) {
                            result.error("DETAILS_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchChapterList" -> {
                    val url = call.argument<String>("url") ?: ""
                    val title = call.argument<String>("title")
                    mainScope.launch {
                        try {
                            val chapters = extensionManager.fetchChapterList(pkg, url, title, apkPath)
                            result.success(chapters)
                        } catch (e: Throwable) {
                            result.error("CHAPTERS_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchPageList" -> {
                    val chapterUrl = call.argument<String>("chapterUrl") ?: ""
                    mainScope.launch {
                        try {
                            val pages = extensionManager.fetchPageList(pkg, chapterUrl, apkPath)
                            result.success(pages)
                        } catch (e: Throwable) {
                            result.error("PAGES_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "fetchImageBytes" -> {
                    val imageUrl = call.argument<String>("imageUrl") ?: call.argument<String>("url") ?: ""
                    val pageUrl = call.argument<String>("pageUrl")
                    mainScope.launch {
                        try {
                            val bytes = extensionManager.fetchImageBytes(pkg, imageUrl, pageUrl, apkPath)
                            result.success(bytes)
                        } catch (e: Throwable) {
                            result.error("IMAGE_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "testAllExtensions" -> {
                    mainScope.launch {
                        val report = mutableMapOf<String, Any?>()
                        val extPackages = getAllExtensionPackages()

                        for (extPkg in extPackages) {
                            try {
                                val popular = extensionManager.fetchPopularManga(extPkg, 1, null)
                                android.util.Log.i("ExtensionTest", "SUCCESS ($extPkg): ${popular.size} items")
                                report[extPkg] = mapOf("status" to "SUCCESS", "count" to popular.size)
                            } catch (t: Throwable) {
                                val msg = extractErrorMessage(t)
                                android.util.Log.e("ExtensionTest", "FAILED ($extPkg): $msg", t)
                                report[extPkg] = mapOf("status" to "ERROR", "message" to msg)
                            }
                        }
                        result.success(report)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_WEBVIEW -> {
                try {
                    android.webkit.CookieManager.getInstance().flush()
                } catch (_: Throwable) {}
                val pending = pendingWebViewResult
                pendingWebViewResult = null
                try {
                    pending?.success(true)
                } catch (_: Throwable) {}
            }
            REQUEST_UNKNOWN_SOURCES -> {
                val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    packageManager.canRequestPackageInstalls()
                } else {
                    true
                }
                pendingUnknownSourcesDeferred?.complete(allowed)
                pendingUnknownSourcesDeferred = null
            }
            REQUEST_ACTION_VIEW_INSTALL -> {
                pendingActionViewInstallDeferred?.complete(Unit)
                pendingActionViewInstallDeferred = null
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        pendingUnknownSourcesDeferred?.let { deferred ->
            val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                packageManager.canRequestPackageInstalls()
            } else {
                true
            }
            if (allowed) {
                deferred.complete(true)
                pendingUnknownSourcesDeferred = null
            }
        }
        ExtensionInstallCoordinator.onHostActivityResumed(applicationContext)
        val testExt = intent?.getBooleanExtra("test_extensions", false) == true
        val testSearch = intent?.getBooleanExtra("test_search", false) == true
        val testDeep = intent?.getBooleanExtra("test_deep", false) == true
        val targetPkg = intent?.getStringExtra("test_pkg")
        val testQuery = intent?.getStringExtra("test_query") ?: "solo"

        if (testExt || testSearch || testDeep || targetPkg != null) {
            intent?.removeExtra("test_extensions")
            intent?.removeExtra("test_search")
            intent?.removeExtra("test_deep")
            intent?.removeExtra("test_pkg")
            intent?.removeExtra("test_query")

            mainScope.launch {
                val extPackages = if (!targetPkg.isNullOrEmpty()) {
                    listOf(targetPkg)
                } else {
                    getAllExtensionPackages()
                }

                android.util.Log.i("ExtensionTest", "Starting test run for ${extPackages.size} extension(s), query='$testQuery', isSearch=$testSearch, isDeep=$testDeep")

                for (extPkg in extPackages) {
                    android.util.Log.i("ExtensionTest", "TESTING ($extPkg)...")
                    try {
                        val items = if (testSearch || !targetPkg.isNullOrEmpty()) {
                            extensionManager.searchManga(extPkg, testQuery, 1, null)
                        } else {
                            extensionManager.fetchPopularManga(extPkg, 1, null)
                        }
                        android.util.Log.i("ExtensionTest", "SEARCH SUCCESS ($extPkg): ${items.size} items, first: ${items.firstOrNull()?.get("title")}")

                        if (testDeep && items.isNotEmpty()) {
                            val first = items.first()
                            val mUrl = first["url"] as? String ?: ""
                            val mTitle = first["title"] as? String
                            android.util.Log.i("ExtensionTest", "TESTING DETAILS ($extPkg): url='$mUrl'...")
                            val details = extensionManager.fetchMangaDetails(extPkg, mUrl, mTitle)
                            android.util.Log.i("ExtensionTest", "DETAILS SUCCESS ($extPkg): author=${details["author"]}, status=${details["status"]}")

                            android.util.Log.i("ExtensionTest", "TESTING CHAPTERS ($extPkg)...")
                            val chapters = extensionManager.fetchChapterList(extPkg, mUrl, mTitle)
                            android.util.Log.i("ExtensionTest", "CHAPTERS SUCCESS ($extPkg): ${chapters.size} chapters, first: ${chapters.firstOrNull()?.get("name")}")

                            val firstChapter = chapters.firstOrNull()
                            if (firstChapter != null) {
                                val cUrl = firstChapter["url"] as? String ?: ""
                                android.util.Log.i("ExtensionTest", "TESTING PAGES ($extPkg): url='$cUrl'...")
                                val pages = extensionManager.fetchPageList(extPkg, cUrl)
                                android.util.Log.i("ExtensionTest", "PAGES SUCCESS ($extPkg): ${pages.size} pages, first page: ${pages.firstOrNull()?.take(60)}")
                            }
                        }
                    } catch (t: Throwable) {
                        val msg = extractErrorMessage(t)
                        android.util.Log.e("ExtensionTest", "FAILED ($extPkg): $msg", t)
                    }
                }
            }
        }
    }
}
