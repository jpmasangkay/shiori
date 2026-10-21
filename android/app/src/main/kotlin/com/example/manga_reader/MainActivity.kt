package com.example.manga_reader

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.manga_reader/installer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "installApk") {
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
            } else if (call.method == "getInstalledExtensions") {
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
            } else if (call.method == "launchPackage") {
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
            } else if (call.method == "isAppInstalled") {
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
            } else {
                result.notImplemented()
            }
        }
    }
}
