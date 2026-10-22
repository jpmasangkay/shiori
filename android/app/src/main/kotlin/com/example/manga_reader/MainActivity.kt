package com.example.manga_reader

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : FlutterActivity() {
    private val INSTALLER_CHANNEL = "com.example.manga_reader/installer"
    private val EXTENSIONS_CHANNEL = "com.example.manga_reader/extensions"

    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val extensionManager by lazy { TachiyomiExtensionManager(applicationContext) }

    private fun extractErrorMessage(e: Throwable): String {
        android.util.Log.e("MainActivity", "Extension execution error: ${e.message}", e)
        var cause: Throwable? = e
        while (cause is java.lang.reflect.InvocationTargetException && cause.targetException != null) {
            cause = cause.targetException
        }
        return cause?.message ?: cause?.toString() ?: e.toString()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Installer & package channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("filePath")
                    if (path != null) {
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "APK file does not exist at $path", null)
                                return@setMethodCallHandler
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                if (!packageManager.canRequestPackageInstalls()) {
                                    val permIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                        data = Uri.parse("package:$packageName")
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(permIntent)
                                    result.success(true)
                                    return@setMethodCallHandler
                                }
                            }

                            val uri = FileProvider.getUriForFile(
                                this,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message ?: "Unknown installation error", null)
                        }
                    } else {
                        result.error("INVALID_ARG", "Path is null", null)
                    }
                }
                "getInstalledExtensions" -> {
                    try {
                        val pm = packageManager
                        val packages = pm.getInstalledPackages(0)
                        val extPackages = packages
                            .map { it.packageName }
                            .filter { it.contains("tachiyomi.extension") || it.startsWith("eu.kanade.tachiyomi") }
                        result.success(extPackages)
                    } catch (e: Exception) {
                        result.error("QUERY_ERROR", e.message ?: "Failed to list extensions", null)
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
                else -> result.notImplemented()
            }
        }

        // Native Tachiyomi Extension Execution Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTENSIONS_CHANNEL).setMethodCallHandler { call, result ->
            val pkg = call.argument<String>("pkg") ?: ""
            val apkPath = call.argument<String>("apkPath")

            if (pkg.isEmpty()) {
                result.error("INVALID_ARG", "pkg must be provided", null)
                return@setMethodCallHandler
            }

            when (call.method) {
                "fetchPopularManga" -> {
                    val page = call.argument<Int>("page") ?: 1
                    mainScope.launch {
                        try {
                            val items = extensionManager.fetchPopularManga(pkg, page, apkPath)
                            result.success(items)
                        } catch (e: Exception) {
                            result.error("FETCH_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                "searchManga" -> {
                    val query = call.argument<String>("query") ?: ""
                    val page = call.argument<Int>("page") ?: 1
                    mainScope.launch {
                        try {
                            val items = if (query.trim().isEmpty()) {
                                extensionManager.fetchPopularManga(pkg, page, apkPath)
                            } else {
                                extensionManager.searchManga(pkg, query, page, apkPath)
                            }
                            result.success(items)
                        } catch (e: Exception) {
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
                        } catch (e: Exception) {
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
                        } catch (e: Exception) {
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
                        } catch (e: Exception) {
                            result.error("PAGES_ERROR", extractErrorMessage(e), null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
