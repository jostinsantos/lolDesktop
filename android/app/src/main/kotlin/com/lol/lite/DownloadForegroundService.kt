package com.lol.lite

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service para mantener vivas las descargas aunque la app pase a segundo plano
 * o se cierre la UI. Flutter sigue ejecutando el isolate mientras el proceso exista;
 * este servicio evita que el sistema mate el proceso con facilidad.
 */
class DownloadForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Descargando…"
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
                val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
                startAsForeground(title, progress, body)
            }
        }
        return START_STICKY
    }

    private fun startAsForeground(title: String, progress: Int, body: String) {
        ensureChannel()
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 40, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(body.ifBlank { "$progress%" })
            .setContentIntent(pi)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, progress.coerceIn(0, 100), progress <= 0)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Descargas en segundo plano",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Mantiene las descargas activas con la app cerrada"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
        }
    }

    companion object {
        const val CHANNEL_ID = "downloads_fg"
        const val NOTIF_ID = 4303
        const val ACTION_START = "com.lol.lite.DOWNLOAD_FG_START"
        const val ACTION_STOP = "com.lol.lite.DOWNLOAD_FG_STOP"
        const val ACTION_UPDATE = "com.lol.lite.DOWNLOAD_FG_UPDATE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_BODY = "body"

        fun start(ctx: Context, title: String, progress: Int, body: String) {
            val i = Intent(ctx, DownloadForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_BODY, body)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }

        fun update(ctx: Context, title: String, progress: Int, body: String) {
            start(ctx, title, progress, body)
        }

        fun stop(ctx: Context) {
            val i = Intent(ctx, DownloadForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                ctx.startService(i)
            } catch (_: Exception) {
                ctx.stopService(Intent(ctx, DownloadForegroundService::class.java))
            }
        }
    }
}
