package com.zanzibarr.zanzibarr

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
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
    private var openFileChannel: MethodChannel? = null
    private var pendingOpenUri: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingOpenUri = if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            null
        } else {
            nzbUriFrom(intent)
        }
        openFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zanzibarr/open_file")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialFile" -> {
                            val uri = pendingOpenUri
                            pendingOpenUri = null
                            if (uri == null) {
                                result.success(null)
                            } else {
                                copyToCache(uri) { path -> result.success(path) }
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = nzbUriFrom(intent) ?: return
        setIntent(intent)
        val channel = openFileChannel
        if (channel == null) {
            pendingOpenUri = uri
            return
        }
        copyToCache(uri) { path ->
            if (path != null) channel.invokeMethod("openFile", path)
        }
    }

    private fun nzbUriFrom(intent: Intent?): Uri? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> null
        }
    }

    private fun copyToCache(uri: Uri, onDone: (String?) -> Unit) {
        Thread {
            val path = try {
                val dir = File(cacheDir, "opened_nzb").apply { mkdirs() }
                val target = File(dir, nzbFileName(uri))
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("cannot open $uri")
                input.use { source ->
                    target.outputStream().use { sink -> source.copyTo(sink) }
                }
                target.absolutePath
            } catch (e: Exception) {
                null
            }
            runOnUiThread { onDone(path) }
        }.start()
    }

    private fun nzbFileName(uri: Uri): String {
        var name: String? = null
        if (uri.scheme == "content") {
            try {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst() && !cursor.isNull(0)) name = cursor.getString(0)
                    }
            } catch (e: Exception) {
                name = null
            }
        }
        if (name.isNullOrBlank()) name = uri.lastPathSegment?.substringAfterLast('/')
        var safe = (name ?: "").replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").trim()
        if (safe.isEmpty() || safe.startsWith(".")) safe = "opened$safe"
        if (!safe.lowercase().endsWith(".nzb")) safe += ".nzb"
        return safe
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
