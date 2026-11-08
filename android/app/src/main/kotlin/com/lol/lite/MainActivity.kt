package com.lol.lite

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.PictureInPictureParams
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Rational
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceControl
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lol.lite/intent"
    private val PIP_CHANNEL = "com.lol.lite/channel"
    private val CLICK_CHANNEL = "tv_webview/click"
    private val DISPLAY_CHANNEL = "app/display_refresh"
    private val CAST_NOTIF_CHANNEL = "com.lol.lite/cast_notif"

    private var methodChannel: MethodChannel? = null
    private var castNotifChannel: MethodChannel? = null

    private val NOTIF_ID = 4201
    private val NOTIF_CHANNEL_ID = "cast_playback"
    private var lastCastTitle: String = "Reproduciendo"
    private var lastCastDevice: String = "Cast"
    private var lastCastPlaying: Boolean = true
    private var lastCastPosMs: Long = 0
    private var lastCastDurMs: Long = 0
    private var lastArtBitmap: Bitmap? = null
    private val bgExecutor = Executors.newSingleThreadExecutor()

    companion object {
        const val ACTION_CAST_PLAY = "com.lol.lite.CAST_PLAY"
        const val ACTION_CAST_PAUSE = "com.lol.lite.CAST_PAUSE"
        const val ACTION_CAST_OPEN = "com.lol.lite.CAST_OPEN"
        const val ACTION_CAST_STOP = "com.lol.lite.CAST_STOP"
    }

    private val castActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_CAST_PLAY -> castNotifChannel?.invokeMethod("play", null)
                ACTION_CAST_PAUSE -> castNotifChannel?.invokeMethod("pause", null)
                ACTION_CAST_OPEN -> castNotifChannel?.invokeMethod("open", null)
                ACTION_CAST_STOP -> castNotifChannel?.invokeMethod("stop", null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestHighestRefreshRate()
        createCastNotificationChannel()
        registerCastReceiver()
        // Programar chequeo periódico de updates de plugins (app cerrada)
        try {
            RepoUpdateWorker.schedule(this)
        } catch (_: Exception) {}
        handleIntent(intent)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(castActionReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        // Si viene de la notificación de cast
        if (intent.getBooleanExtra("open_cast", false)) {
            castNotifChannel?.invokeMethod("open", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4202 &&
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            // Usuario acaba de conceder el permiso → mostrar la notificación pendiente
            postCastNotification()
        }
    }

    private fun registerCastReceiver() {
        val filter = IntentFilter().apply {
            addAction(ACTION_CAST_PLAY)
            addAction(ACTION_CAST_PAUSE)
            addAction(ACTION_CAST_OPEN)
            addAction(ACTION_CAST_STOP)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(castActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(castActionReceiver, filter)
        }
    }

    private fun createCastNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "Reproducción Cast",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Control de transmisión Cast / Chromecast"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm?.createNotificationChannel(channel)
        }
    }

    private fun ensureNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        val granted = ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                4202
            )
        }
        return granted
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        // ── Picture-in-Picture ───────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPip" -> result.success(enterPipMode())
                    "exitPip" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) {
                                result.success(false)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "isInPip" -> {
                        result.success(
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode
                        )
                    }
                    "isPipSupported" -> result.success(isPipSupported())
                    else -> result.notImplemented()
                }
            }

        // ── Click nativo de la mira (WebView TV) ─────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLICK_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "injectClick") {
                    val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                    val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                    injectNativeClick(x, y)
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }

        // ── Tasa de refresco (Hz) de la pantalla ─────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestHighestRefreshRate" -> result.success(requestHighestRefreshRate())
                    "getRefreshRate" -> result.success(currentRefreshRate())
                    else -> result.notImplemented()
                }
            }

        // ── Notificación de Cast ─────────────────────────────────────────
        castNotifChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAST_NOTIF_CHANNEL)
        castNotifChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "show", "update" -> {
                    val title = call.argument<String>("title") ?: "Reproduciendo"
                    val device = call.argument<String>("device") ?: "Cast"
                    val playing = call.argument<Boolean>("playing") ?: true
                    val posMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                    val durMs = (call.argument<Number>("durationMs") ?: 0).toLong()
                    val imageUrl = call.argument<String>("imageUrl")
                    lastCastTitle = title
                    lastCastDevice = device
                    lastCastPlaying = playing
                    lastCastPosMs = posMs
                    lastCastDurMs = durMs
                    // Pedir permiso de notificaciones en Android 13+ si aún no se tiene
                    ensureNotificationPermission()
                    if (!imageUrl.isNullOrBlank() && lastArtBitmap == null) {
                        bgExecutor.execute {
                            lastArtBitmap = loadBitmap(imageUrl)
                            runOnUiThread { postCastNotification() }
                        }
                    }
                    postCastNotification()
                    result.success(true)
                }
                "hide" -> {
                    NotificationManagerCompat.from(this).cancel(NOTIF_ID)
                    lastArtBitmap = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Updates de plugins en background (WorkManager) ─────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lol.lite/bg_updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        RepoUpdateWorker.schedule(this)
                        result.success(true)
                    }
                    "scheduleNow" -> {
                        RepoUpdateWorker.scheduleNow(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Descargas: foreground service + conversión ────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lol.lite/downloads")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        ensureNotificationPermission()
                        val title = call.argument<String>("title") ?: "Descargando"
                        val progress = call.argument<Int>("progress") ?: 0
                        val count = call.argument<Int>("count") ?: 1
                        val repo = call.argument<String>("repo") ?: ""
                        val soft = call.argument<Boolean>("soft") == true
                        val body = buildString {
                            append(progress.coerceIn(0, 100)).append("%")
                            if (repo.isNotBlank()) append(" · ").append(repo)
                            if (count > 1) append(" · ").append(count).append(" activas")
                        }
                        if (soft) {
                            // TV: toast corto (≈3s) en vez de notificación del sistema
                            android.widget.Toast.makeText(
                                this,
                                "$title · $body",
                                android.widget.Toast.LENGTH_SHORT
                            ).show()
                        } else {
                            DownloadForegroundService.update(this, title, progress, body)
                        }
                        result.success(true)
                    }
                    "hide" -> {
                        DownloadForegroundService.stop(this)
                        result.success(true)
                    }
                    "convert" -> {
                        bgExecutor.execute {
                            try {
                                val input = call.argument<String>("input")
                                val kind = call.argument<String>("kind") ?: ""
                                val outputDir = call.argument<String>("outputDir")
                                val title = call.argument<String>("title") ?: "video"
                                val out = convertDownload(input, kind, outputDir, title)
                                runOnUiThread {
                                    if (out != null) result.success(out)
                                    else result.error("convert_fail", "No se pudo convertir/guardar", null)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("convert_fail", e.message, null)
                                }
                            }
                        }
                    }
                    "deletePublic" -> {
                        bgExecutor.execute {
                            try {
                                val path = call.argument<String>("path")
                                val title = call.argument<String>("title")
                                deletePublicDownload(path, title)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.success(false) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Concatena HLS/TS y guarda en Descargas/lollite vía MediaStore (API 29+)
     * o File directo (API <=28 / fallback).
     */
    private fun convertDownload(
        input: String?,
        kind: String,
        outputDir: String?,
        title: String
    ): String? {
        if (input.isNullOrBlank()) return null
        val inFile = java.io.File(input)
        if (!inFile.exists() && !inFile.parentFile!!.exists()) return null
        val workDir = if (!outputDir.isNullOrBlank()) java.io.File(outputDir)
            else inFile.parentFile ?: return null

        // 1) Construir archivo temporal en cache interna
        val tmpDir = java.io.File(cacheDir, "convert_tmp").apply { mkdirs() }
        val safe = title.replace(Regex("[^A-Za-z0-9._-]"), "_").take(40).ifBlank { "video" }
        val isHls = kind == "hls" || inFile.name.endsWith(".m3u8") ||
            (inFile.parentFile?.name == "hls")
        val isTs = kind == "ts" || input.endsWith(".ts")
        val ext = when {
            isHls -> "mp4"
            isTs -> "mkv"
            inFile.name.contains('.') -> inFile.name.substringAfterLast('.')
            else -> "mp4"
        }
        val tmpOut = java.io.File(tmpDir, "${safe}_converted.$ext")

        if (isHls) {
            val segDir = when {
                inFile.isDirectory -> inFile
                inFile.name.endsWith(".m3u8") -> inFile.parentFile ?: workDir
                inFile.parentFile?.name == "hls" -> inFile.parentFile!!
                else -> workDir
            }
            val segs = segDir.listFiles { f ->
                f.isFile && (f.name.startsWith("seg_") || f.name.endsWith(".ts"))
            }?.sortedBy { it.name } ?: emptyList()
            if (segs.isEmpty()) {
                // Intentar copiar el propio archivo si es progresivo mal etiquetado
                if (inFile.isFile) inFile.copyTo(tmpOut, overwrite = true)
                else return null
            } else {
                java.io.FileOutputStream(tmpOut).use { fos ->
                    for (s in segs) s.inputStream().use { it.copyTo(fos) }
                }
            }
        } else {
            if (!inFile.isFile) return null
            inFile.copyTo(tmpOut, overwrite = true)
        }

        if (!tmpOut.exists() || tmpOut.length() == 0L) return null

        val mime = when (ext) {
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "ts" -> "video/mp2t"
            "webm" -> "video/webm"
            else -> "application/octet-stream"
        }
        val displayName = "${safe}_converted.$ext"

        // 2) Guardar en Descargas/lollite
        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            saveToDownloadsMediaStore(tmpOut, displayName, mime)
        } else {
            saveToDownloadsLegacy(tmpOut, displayName)
        }.also {
            try { tmpOut.delete() } catch (_: Exception) {}
        }
    }

    private fun saveToDownloadsMediaStore(
        src: java.io.File,
        displayName: String,
        mime: String
    ): String? {
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(android.provider.MediaStore.Downloads.MIME_TYPE, mime)
            put(
                android.provider.MediaStore.Downloads.RELATIVE_PATH,
                android.os.Environment.DIRECTORY_DOWNLOADS + "/lollite"
            )
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
            }
        }
        val collection = android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = contentResolver.insert(collection, values) ?: return saveToDownloadsLegacy(src, displayName)
        try {
            contentResolver.openOutputStream(uri)?.use { os ->
                src.inputStream().use { it.copyTo(os) }
            } ?: return null
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                values.clear()
                values.put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            }
            // Resolver path real si es posible
            val path = queryPathFromUri(uri)
            return path ?: uri.toString()
        } catch (e: Exception) {
            try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            e.printStackTrace()
            return saveToDownloadsLegacy(src, displayName)
        }
    }

    private fun saveToDownloadsLegacy(src: java.io.File, displayName: String): String? {
        return try {
            val publicDir = java.io.File(
                android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS
                ),
                "lollite"
            )
            if (!publicDir.exists()) {
                val ok = publicDir.mkdirs()
                if (!ok && !publicDir.exists()) {
                    // Fallback: almacenamiento de la app en externo
                    val alt = getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS)
                    val altDir = java.io.File(alt, "lollite").apply { mkdirs() }
                    val out = java.io.File(altDir, displayName)
                    src.copyTo(out, overwrite = true)
                    return out.absolutePath
                }
            }
            val out = java.io.File(publicDir, displayName)
            src.copyTo(out, overwrite = true)
            try {
                android.media.MediaScannerConnection.scanFile(
                    this, arrayOf(out.absolutePath), null, null
                )
            } catch (_: Exception) {}
            out.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun queryPathFromUri(uri: android.net.Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(android.provider.MediaStore.Downloads.DATA), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        val idx = c.getColumnIndex(android.provider.MediaStore.Downloads.DATA)
                        if (idx >= 0) c.getString(idx) else null
                    } else null
                }
        } catch (_: Exception) {
            null
        }
    }

    /** Borra archivo público en Descargas/lollite y por MediaStore. */
    private fun deletePublicDownload(path: String?, title: String?) {
        // Por path directo
        if (!path.isNullOrBlank() && !path.startsWith("content:")) {
            try {
                val f = java.io.File(path)
                if (f.exists()) f.delete()
                // Si está dentro de una carpeta de descarga de la app, borrar carpeta
                var parent = f.parentFile
                while (parent != null) {
                    if (parent.name.contains("lol_downloads") || parent.parentFile?.name == "lol_downloads") {
                        parent.deleteRecursively()
                        break
                    }
                    // carpeta lollite: solo el archivo
                    if (parent.name == "lollite") break
                    parent = parent.parentFile
                }
            } catch (_: Exception) {}
        }
        // MediaStore por nombre
        val safe = (title ?: "").replace(Regex("[^A-Za-z0-9._-]"), "_").take(40)
        if (safe.isBlank()) return
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                val coll = android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
                contentResolver.delete(
                    coll,
                    android.provider.MediaStore.Downloads.DISPLAY_NAME + " LIKE ?",
                    arrayOf("%${safe}%")
                )
            }
        } catch (_: Exception) {}
        // Carpeta pública lollite
        try {
            val publicDir = java.io.File(
                android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS
                ),
                "lollite"
            )
            publicDir.listFiles()?.forEach { f ->
                if (f.name.contains(safe)) f.delete()
            }
        } catch (_: Exception) {}
    }

    private fun loadBitmap(url: String): Bitmap? {
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 4000
            conn.readTimeout = 4000
            conn.doInput = true
            conn.connect()
            val bmp = BitmapFactory.decodeStream(conn.inputStream)
            conn.disconnect()
            bmp
        } catch (_: Exception) {
            null
        }
    }

    private fun postCastNotification() {
        // Si no hay permiso aún (usuario no ha respondido al diálogo), no intentamos
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return
        }

        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_cast", true)
        }
        val openPi = PendingIntent.getActivity(
            this, 10, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playPauseAction = if (lastCastPlaying) {
            NotificationCompat.Action(
                android.R.drawable.ic_media_pause,
                "Pausa",
                PendingIntent.getBroadcast(
                    this, 11,
                    Intent(ACTION_CAST_PAUSE).setPackage(packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        } else {
            NotificationCompat.Action(
                android.R.drawable.ic_media_play,
                "Play",
                PendingIntent.getBroadcast(
                    this, 12,
                    Intent(ACTION_CAST_PLAY).setPackage(packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        val stopAction = NotificationCompat.Action(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Detener",
            PendingIntent.getBroadcast(
                this, 13,
                Intent(ACTION_CAST_STOP).setPackage(packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )

        val builder = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(lastCastTitle)
            .setContentText("Conectado a $lastCastDevice")
            .setContentIntent(openPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(playPauseAction)
            .addAction(stopAction)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setShowActionsInCompactView(0, 1)
            )

        if (lastCastDurMs > 0) {
            builder.setProgress(
                lastCastDurMs.toInt().coerceAtLeast(1),
                lastCastPosMs.toInt().coerceIn(0, lastCastDurMs.toInt()),
                false
            )
            val posSec = lastCastPosMs / 1000
            val durSec = lastCastDurMs / 1000
            val posStr = String.format("%d:%02d", posSec / 60, posSec % 60)
            val durStr = String.format("%d:%02d", durSec / 60, durSec % 60)
            builder.setSubText("$posStr / $durStr · $lastCastDevice")
        } else {
            builder.setSubText(lastCastDevice)
        }

        lastArtBitmap?.let { builder.setLargeIcon(it) }

        try {
            NotificationManagerCompat.from(this).notify(NOTIF_ID, builder.build())
        } catch (e: SecurityException) {
            // Sin permiso POST_NOTIFICATIONS en Android 13+
            e.printStackTrace()
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REFRESCO MÁXIMO DE PANTALLA (60 / 90 / 120 / 144 Hz)
    // ═══════════════════════════════════════════════════════════════════════

    private fun requestHighestRefreshRate(): Double {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return currentRefreshRate()
        }
        val display = windowManager.defaultDisplay
        val modes = display.supportedModes
        val best = modes.maxByOrNull { it.refreshRate } ?: return currentRefreshRate()

        val params = window.attributes
        params.preferredDisplayModeId = best.modeId
        window.attributes = params
        return best.refreshRate.toDouble()
    }

    private fun currentRefreshRate(): Double {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                windowManager.defaultDisplay.mode.refreshRate.toDouble()
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay.refreshRate.toDouble()
            }
        } catch (_: Exception) {
            60.0
        }
    }

    private fun injectNativeClick(flutterX: Float, flutterY: Float) {
        try {
            val root = window.decorView.rootView
            val webView = findWebView(root) ?: return
            val loc = IntArray(2)
            webView.getLocationOnScreen(loc)
            val x = flutterX - loc[0]
            val y = flutterY - loc[1]
            val down = SystemClock.uptimeMillis()
            val eventDown = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
            val eventUp = MotionEvent.obtain(down, down + 50, MotionEvent.ACTION_UP, x, y, 0)
            webView.dispatchTouchEvent(eventDown)
            webView.dispatchTouchEvent(eventUp)
            eventDown.recycle()
            eventUp.recycle()
        } catch (_: Exception) {}
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findWebView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    private fun isPipSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun enterPipMode(): Boolean {
        if (!isPipSupported()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build()
                enterPictureInPictureMode(params)
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        try {
            if (isPipSupported() &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                !isInPictureInPictureMode
            ) {
                // No auto-entrar siempre: solo cuando Flutter lo pida.
            }
        } catch (_: Exception) {}
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        }
        try {
            methodChannel?.invokeMethod(
                "onPipModeChanged",
                mapOf("isInPip" to isInPictureInPictureMode)
            )
        } catch (_: Exception) {}
    }

    private fun handleIntent(intent: Intent) {
        val data = intent.data
        data?.let { uri ->
            when {
                uri.scheme == "lol_lite" && uri.host == "user" -> {
                    val userId = uri.path?.replaceFirst("/", "") ?: ""
                    if (userId.isNotEmpty()) {
                        sendToFlutter("user", userId)
                    }
                }
                uri.scheme == "lol_lite" && uri.host == "content" -> {
                    val idcontenido = uri.path?.replaceFirst("/", "") ?: ""
                    if (idcontenido.isNotEmpty() && idcontenido.all { it.isDigit() }) {
                        sendToFlutter("content", idcontenido)
                    } else {
                        println("❌ ID de contenido inválido: $idcontenido")
                    }
                }
                uri.scheme == "lol_lite" && uri.host == "list" -> {
                    val filter = uri.path?.replaceFirst("/", "") ?: ""
                    if (filter.isNotEmpty()) {
                        sendToFlutter("list", filter)
                    }
                }
                else -> {
                    val url = uri.toString()
                    if (url.isNotEmpty()) {
                        sendToFlutter("url", url)
                    }
                }
            }
        }
        if (intent.getBooleanExtra("open_cast", false)) {
            castNotifChannel?.invokeMethod("open", null)
        }
    }

    private fun sendToFlutter(type: String, value: String) {
        try {
            val data = mapOf(
                "type" to type,
                "value" to value
            )
            methodChannel?.invokeMethod("openDeepLink", data)
            println("📱 Enviando a Flutter: type=$type, value=$value")
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
