package com.zanzibarr.zanzibarr

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var windowChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        windowChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zanzibarr/window")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "enterPictureInPicture" -> result.success(
                            enterPictureInPicture(
                                call.argument<Int>("width"),
                                call.argument<Int>("height"),
                            ),
                        )
                        "exitPictureInPicture" -> result.success(true)
                        else -> result.notImplemented()
                    }
                }
            }
        // OTA güncelleme: indirilen APK'nın sistem yükleyicisiyle kurulması.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zanzibarr/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path eksik", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enterPictureInPicture(width: Int?, height: Int?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return false
        val builder = PictureInPictureParams.Builder()
        if (width != null && height != null && width > 0 && height > 0) {
            val ratio = width.toDouble() / height
            builder.setAspectRatio(
                when {
                    ratio > 2.39 -> Rational(239, 100)
                    ratio < 1 / 2.39 -> Rational(100, 239)
                    else -> Rational(width, height)
                },
            )
        }
        return try {
            enterPictureInPictureMode(builder.build())
        } catch (e: IllegalStateException) {
            false
        } catch (e: IllegalArgumentException) {
            false
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        val dismissed = !isInPictureInPictureMode &&
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        windowChannel?.invokeMethod(
            "pictureInPictureChanged",
            mapOf("active" to isInPictureInPictureMode, "dismissed" to dismissed),
        )
    }
}
