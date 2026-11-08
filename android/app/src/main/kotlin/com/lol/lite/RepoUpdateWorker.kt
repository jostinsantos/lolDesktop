package com.lol.lite

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Comprueba actualizaciones de repos (manifest remoto) y notifica.
 * Sin WorkManager: se ejecuta en un hilo al abrir la app / bajo demanda.
 */
object RepoUpdateWorker {

    private const val CHANNEL_ID = "repo_updates"
    private const val NOTIF_ID = 4301
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY_INSTALLED = "flutter.installed_repos"
    private val executor = Executors.newSingleThreadExecutor()

    @JvmStatic
    fun schedule(context: Context) {
        executor.execute {
            try {
                val updates = checkUpdates(context.applicationContext)
                if (updates.isNotEmpty()) {
                    showNotification(context.applicationContext, updates)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    @JvmStatic
    fun scheduleNow(context: Context) {
        schedule(context)
    }

    private fun checkUpdates(ctx: Context): List<Pair<String, String>> {
        val prefs = ctx.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_INSTALLED, null) ?: return emptyList()
        val list = try {
            JSONArray(raw)
        } catch (_: Exception) {
            return emptyList()
        }
        val found = mutableListOf<Pair<String, String>>()
        for (i in 0 until list.length()) {
            val obj = list.optJSONObject(i) ?: continue
            val name = obj.optString("name", obj.optString("id", "Repo"))
            val version = obj.optString("version", "")
            val repo = obj.optString("repo", "")
            val manifestUrl = obj.optString("manifestUrl", "")
                .ifBlank {
                    if (repo.isNotBlank()) {
                        "https://raw.githubusercontent.com/$repo/main/manifest.json"
                    } else ""
                }
            if (manifestUrl.isBlank() || version.isBlank()) continue
            try {
                val remote = fetchJson(manifestUrl) ?: continue
                val remoteVer = remote.optString("version", "")
                if (remoteVer.isNotBlank() && remoteVer != version) {
                    found.add(name to "$version → $remoteVer")
                }
            } catch (_: Exception) {
            }
        }
        return found
    }

    private fun fetchJson(urlStr: String): org.json.JSONObject? {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 8000
        conn.requestMethod = "GET"
        conn.setRequestProperty("Accept", "application/json")
        return try {
            if (conn.responseCode in 200..299) {
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                org.json.JSONObject(body)
            } else null
        } finally {
            conn.disconnect()
        }
    }

    private fun showNotification(ctx: Context, updates: List<Pair<String, String>>) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Actualizaciones de plugins",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "Aviso cuando un plugin tiene nueva versión" }
            ctx.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(ch)
        }
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            ctx, 20, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val lines = updates.joinToString("\n") { "• ${it.first}: ${it.second}" }
        val builder = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(
                if (updates.size == 1) "Plugin actualizable"
                else "${updates.size} plugins actualizables"
            )
            .setContentText(updates.firstOrNull()?.let { "${it.first}: ${it.second}" } ?: "")
            .setStyle(NotificationCompat.BigTextStyle().bigText(lines))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        try {
            NotificationManagerCompat.from(ctx).notify(NOTIF_ID, builder.build())
        } catch (_: SecurityException) {
        }
    }
}
