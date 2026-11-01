package com.example.manga_reader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

sealed class InstallOutcome {
    data object Success : InstallOutcome()
    data class Failure(val code: String, val message: String) : InstallOutcome()
}

object ExtensionInstallCoordinator {
    const val EXTRA_SHIORI_SESSION_ID = "shiori_session_id"
    const val EXTRA_SHIORI_TARGET_PKG = "shiori_target_pkg"

    data class PendingSession(
        val sessionId: Int,
        val targetPkg: String,
        val expectedVersionCode: Long,
        val deferred: CompletableDeferred<InstallOutcome>,
        @Volatile var userActionStarted: Boolean = false,
        @Volatile var confirmationClosed: Boolean = false
    )

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<Int, PendingSession>()

    fun registerSession(
        sessionId: Int,
        targetPkg: String,
        expectedVersionCode: Long
    ): CompletableDeferred<InstallOutcome> {
        val deferred = CompletableDeferred<InstallOutcome>()
        sessions[sessionId] = PendingSession(
            sessionId = sessionId,
            targetPkg = targetPkg,
            expectedVersionCode = expectedVersionCode,
            deferred = deferred
        )
        return deferred
    }

    fun markUserActionStarted(sessionId: Int) {
        sessions[sessionId]?.userActionStarted = true
    }

    fun completeSession(sessionId: Int, outcome: InstallOutcome) {
        val pending = sessions.remove(sessionId)
        if (pending != null) {
            pending.deferred.complete(outcome)
            return
        }
        // Fallback if PackageInstaller omitted session ID extra and only 1 session is active
        if (sessionId == -1 && sessions.size == 1) {
            val soleKey = sessions.keys.firstOrNull() ?: return
            sessions.remove(soleKey)?.deferred?.complete(outcome)
        }
    }

    fun removeSession(sessionId: Int) {
        sessions.remove(sessionId)
    }

    fun hasActiveSessionForPkg(pkg: String): Boolean {
        val normalized = pkg.trim().lowercase()
        return sessions.values.any { it.targetPkg.lowercase() == normalized }
    }

    fun onPackageInstalledBroadcast(context: Context, pkg: String) {
        val normalized = pkg.trim().lowercase()
        if (normalized.isEmpty()) return
        val installedCode = getInstalledVersionCode(context, pkg)
        for ((id, session) in sessions.entries) {
            if (session.targetPkg.lowercase() == normalized) {
                if (session.expectedVersionCode <= 0L || installedCode >= session.expectedVersionCode) {
                    sessions.remove(id)?.deferred?.complete(InstallOutcome.Success)
                }
            }
        }
    }

    fun onConfirmationDialogClosed(context: Context, sessionId: Int) {
        val pending = sessions[sessionId]
            ?: (if (sessions.size == 1) sessions.values.firstOrNull() else null)
            ?: return
        pending.confirmationClosed = true
        val appCtx = context.applicationContext
        scope.launch {
            val pmInstaller = appCtx.packageManager.packageInstaller
            // Poll while the PackageInstaller session finishes committing or until cancelled.
            var inactiveTicks = 0
            for (i in 0 until 80) { // up to 20s if actively installing
                if (!sessions.containsKey(pending.sessionId)) return@launch

                if (pending.targetPkg.isNotEmpty()) {
                    val installedVer = getInstalledVersionCode(appCtx, pending.targetPkg)
                    if (installedVer > 0L &&
                        (pending.expectedVersionCode <= 0L || installedVer >= pending.expectedVersionCode)
                    ) {
                        completeSession(pending.sessionId, InstallOutcome.Success)
                        return@launch
                    }
                }

                val sessionInfo = try {
                    pmInstaller.getSessionInfo(pending.sessionId)
                } catch (_: Throwable) {
                    null
                }
                if (sessionInfo == null || !sessionInfo.isActive) {
                    inactiveTicks++
                    // Give STATUS_SUCCESS / ACTION_PACKAGE_REPLACED ~1s grace after session closes
                    if (inactiveTicks >= 4) {
                        val finalVer = if (pending.targetPkg.isNotEmpty()) {
                            getInstalledVersionCode(appCtx, pending.targetPkg)
                        } else {
                            -1L
                        }
                        if (finalVer > 0L &&
                            (pending.expectedVersionCode <= 0L || finalVer >= pending.expectedVersionCode)
                        ) {
                            completeSession(pending.sessionId, InstallOutcome.Success)
                        } else {
                            try {
                                pmInstaller.abandonSession(pending.sessionId)
                            } catch (_: Throwable) {}
                            completeSession(
                                pending.sessionId,
                                InstallOutcome.Failure("INSTALL_CANCELLED", "Update cancelled.")
                            )
                        }
                        return@launch
                    }
                } else {
                    inactiveTicks = 0
                }
                delay(250L)
            }
        }
    }

    fun onHostActivityResumed(context: Context) {
        val appCtx = context.applicationContext
        for ((id, session) in sessions.entries) {
            if (session.userActionStarted && !session.confirmationClosed) {
                onConfirmationDialogClosed(appCtx, id)
            }
        }
    }

    @Suppress("DEPRECATION")
    fun getInstalledVersionCode(context: Context, pkg: String): Long {
        if (pkg.isBlank()) return -1L
        return try {
            val pm = context.packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                pm.getPackageInfo(pkg, 0)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                info.versionCode.toLong()
            }
        } catch (_: Throwable) {
            -1L
        }
    }
}

/**
 * Translucent trampoline Activity invoked directly by Android's [PackageInstaller] via
 * [android.app.PendingIntent.getActivity]. Launching the confirmation prompt from a real
 * foreground Activity avoids Android 14–16 Background Activity Launch (BAL) blocks and
 * reliably detects user confirmation or cancellation.
 */
class ExtensionInstallActivity : Activity() {
    companion object {
        private const val REQUEST_CONFIRM_INSTALL = 9402
    }

    private var activeSessionId: Int = -1
    private var waitingForConfirmationResult: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
        handleInstallerIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        if (intent != null) {
            setIntent(intent)
            handleInstallerIntent(intent)
        }
    }

    private fun handleInstallerIntent(intent: Intent?) {
        if (intent == null) {
            finishQuietly()
            return
        }

        val sessionIdFromExtra = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val sessionId = if (sessionIdFromExtra != -1) {
            sessionIdFromExtra
        } else {
            intent.getIntExtra(ExtensionInstallCoordinator.EXTRA_SHIORI_SESSION_ID, -1)
        }
        if (sessionId != -1) {
            activeSessionId = sessionId
        }

        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE
        )
        val pkgName = intent.getStringExtra(PackageInstaller.EXTRA_PACKAGE_NAME)
            ?: intent.getStringExtra(ExtensionInstallCoordinator.EXTRA_SHIORI_TARGET_PKG)
            ?: ""
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }

                if (confirmIntent == null) {
                    ExtensionInstallCoordinator.completeSession(
                        activeSessionId,
                        InstallOutcome.Failure("CONFIRM_MISSING", "System installer confirmation intent was missing.")
                    )
                    finishQuietly()
                    return
                }

                ExtensionInstallCoordinator.markUserActionStarted(activeSessionId)
                try {
                    confirmIntent.removeFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    waitingForConfirmationResult = true
                    @Suppress("DEPRECATION")
                    startActivityForResult(confirmIntent, REQUEST_CONFIRM_INSTALL)
                } catch (e: Throwable) {
                    waitingForConfirmationResult = false
                    try {
                        confirmIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(confirmIntent)
                        finishQuietly()
                    } catch (e2: Throwable) {
                        android.util.Log.e(
                            "ExtensionInstallAct",
                            "Failed to launch PackageInstaller confirmation for $pkgName: ${e2.message}",
                            e2
                        )
                        ExtensionInstallCoordinator.completeSession(
                            activeSessionId,
                            InstallOutcome.Failure(
                                "CONFIRM_LAUNCH_ERROR",
                                "Failed to open Android package installer: ${e2.message}"
                            )
                        )
                        finishQuietly()
                    }
                }
            }

            PackageInstaller.STATUS_SUCCESS -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(activeSessionId, InstallOutcome.Success)
                finishQuietly()
            }

            PackageInstaller.STATUS_FAILURE_ABORTED -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure("INSTALL_CANCELLED", "Update cancelled.")
                )
                finishQuietly()
            }

            PackageInstaller.STATUS_FAILURE_CONFLICT -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure(
                        "SIGNATURE_CONFLICT",
                        "Conflicting signature with installed extension. Uninstall the existing extension first, then install again."
                    )
                )
                finishQuietly()
            }

            PackageInstaller.STATUS_FAILURE_BLOCKED -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure(
                        "INSTALL_BLOCKED",
                        "Installation blocked by device security (check Auto Blocker / Play Protect)."
                    )
                )
                finishQuietly()
            }

            PackageInstaller.STATUS_FAILURE_STORAGE -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure("INSUFFICIENT_STORAGE", "Not enough storage space to install extension.")
                )
                finishQuietly()
            }

            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> {
                waitingForConfirmationResult = false
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure("INSTALL_INCOMPATIBLE", "Extension APK is incompatible with this device.")
                )
                finishQuietly()
            }

            else -> {
                waitingForConfirmationResult = false
                android.util.Log.w(
                    "ExtensionInstallAct",
                    "PackageInstaller status=$status for $pkgName: $message"
                )
                ExtensionInstallCoordinator.completeSession(
                    activeSessionId,
                    InstallOutcome.Failure(
                        "INSTALL_FAILED",
                        message.ifEmpty { "Package installation failed (code $status)." }
                    )
                )
                finishQuietly()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CONFIRM_INSTALL) {
            waitingForConfirmationResult = false
            ExtensionInstallCoordinator.onConfirmationDialogClosed(applicationContext, activeSessionId)
            finishQuietly()
        }
    }

    private fun finishQuietly() {
        if (!isFinishing) {
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}

