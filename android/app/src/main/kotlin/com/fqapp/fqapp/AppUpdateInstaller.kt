package com.fqapp.fqapp

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.security.MessageDigest

class AppUpdateFileProvider : FileProvider()

internal class AppUpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(
        messenger,
        "fqapp/app_update",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    )
    private val apkName = Regex("""fqapp-\d{1,6}\.\d{1,6}\.\d{1,6}\.apk""")
    private val manager get() = activity.packageManager
    private val packageName get() = activity.packageName
    private val officialSigner =
        "e8471cd8a935fd71fd8197355b5558d245449d5bc8294f60f88616f60451c550"

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "device" -> {
                        val current = installed()
                        result.success(
                            mapOf(
                                "version" to current.versionName,
                                "abis" to Build.SUPPORTED_ABIS.toList(),
                                "supported" to canUpdate(current),
                            ),
                        )
                    }
                    "permissionSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            canUpdate(installed())
                        ) {
                            launch(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.fromParts("package", packageName, null),
                                ),
                                result,
                                null,
                            )
                        } else {
                            result.success(null)
                        }
                    }
                    "install" -> install(call.arguments as? String, result)
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("update_install", "系统无法打开更新安装界面", null)
            }
        }
    }

    fun detach() = channel.setMethodCallHandler(null)

    @Suppress("DEPRECATION")
    private fun signingFlag() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    @Suppress("DEPRECATION")
    private fun installed() = manager.getPackageInfo(packageName, signingFlag())

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        return signatures.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }.toSet()
    }

    private fun canUpdate(info: PackageInfo) =
        packageName == "com.fqapp.fqapp" && signers(info) == setOf(officialSigner)

    @Suppress("DEPRECATION")
    private fun install(name: String?, result: MethodChannel.Result) {
        if (name == null || !apkName.matches(name)) return result.success("invalid")
        val current = installed()
        if (!canUpdate(current)) return result.success("invalid")
        val file = File(File(activity.cacheDir, "app_updates"), name)
        if (!file.isFile) return result.success("invalid")
        val candidate = manager.getPackageArchiveInfo(file.path, signingFlag())
            ?: return result.success("invalid")
        if (candidate.packageName != packageName ||
            signers(candidate) != setOf(officialSigner) ||
            PackageInfoCompat.getLongVersionCode(candidate) <= PackageInfoCompat.getLongVersionCode(current)
        ) return result.success("invalid")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !manager.canRequestPackageInstalls()) {
            return result.success("permission")
        }
        val uri = FileProvider.getUriForFile(activity, "$packageName.app_update", file)
        launch(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            result,
            "opened",
        )
    }

    private fun launch(intent: Intent, result: MethodChannel.Result, value: String?) {
        activity.runOnUiThread {
            try {
                activity.startActivity(intent)
                result.success(value)
            } catch (_: Exception) {
                result.error("update_install", "系统无法打开更新安装界面", null)
            }
        }
    }
}
