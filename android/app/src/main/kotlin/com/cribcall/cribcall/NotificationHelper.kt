package com.cribcall.cribcall

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Centralized helper for foreground service notifications.
 *
 * Consolidates notification channel creation and notification building
 * across AudioCaptureService, MonitorService, and ListenerService.
 */
object NotificationHelper {

    // Channel for audio capture (microphone monitoring)
    const val CHANNEL_ID_AUDIO_CAPTURE = "cribcall_monitoring"
    private const val CHANNEL_NAME_AUDIO_CAPTURE = "Baby Monitor"

    // Channel for control server (WebSocket server)
    const val CHANNEL_ID_CONTROL_SERVER = "cribcall_monitor"
    private const val CHANNEL_NAME_CONTROL_SERVER = "Monitor Server"

    // Channel for listener (connected to monitor)
    const val CHANNEL_ID_LISTENER = "cribcall_listener"
    private const val CHANNEL_NAME_LISTENER = "Baby Monitor Listener"

    /**
     * Create all notification channels. Call this on app startup.
     */
    fun createNotificationChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            listOf(
                NotificationChannel(
                    CHANNEL_ID_AUDIO_CAPTURE,
                    CHANNEL_NAME_AUDIO_CAPTURE,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows when CribCall is monitoring for sounds"
                    setShowBadge(false)
                },
                NotificationChannel(
                    CHANNEL_ID_CONTROL_SERVER,
                    CHANNEL_NAME_CONTROL_SERVER,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Active when CribCall monitor server is running"
                    setShowBadge(false)
                },
                NotificationChannel(
                    CHANNEL_ID_LISTENER,
                    CHANNEL_NAME_LISTENER,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Listening for baby monitor alerts"
                    setShowBadge(false)
                }
            ).forEach { notificationManager.createNotificationChannel(it) }
        }
    }

    /**
     * Build a foreground service notification.
     *
     * @param context The context
     * @param channelId The notification channel ID
     * @param title The notification title
     * @param text The notification body text
     * @param serviceClass The service class for the stop action
     * @param stopAction The action string for the stop button
     * @param notificationId The notification ID (used to create unique pending intent)
     * @param smallIcon The small icon resource ID
     */
    fun buildForegroundNotification(
        context: Context,
        channelId: String,
        title: String,
        text: String,
        serviceClass: Class<*>,
        stopAction: String,
        notificationId: Int,
        smallIcon: Int = android.R.drawable.ic_media_play
    ): Notification {
        // Create intent to open the app when notification is tapped
        val mainIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val mainPendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            mainIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Create stop action pending intent
        val stopIntent = Intent(context, serviceClass).apply {
            action = stopAction
        }
        val stopPendingIntent = PendingIntent.getService(
            context,
            notificationId + 1000,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            buildNotificationOreo(
                context, channelId, title, text, smallIcon, mainPendingIntent, stopPendingIntent
            )
        } else {
            buildNotificationLegacy(
                context, title, text, smallIcon, mainPendingIntent, stopPendingIntent
            )
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildNotificationOreo(
        context: Context,
        channelId: String,
        title: String,
        text: String,
        smallIcon: Int,
        contentIntent: PendingIntent,
        stopIntent: PendingIntent
    ): Notification {
        return Notification.Builder(context, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(smallIcon)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(
                Notification.Action.Builder(null, "Stop", stopIntent).build()
            )
            .build()
    }

    @Suppress("DEPRECATION")
    private fun buildNotificationLegacy(
        context: Context,
        title: String,
        text: String,
        smallIcon: Int,
        contentIntent: PendingIntent,
        stopIntent: PendingIntent
    ): Notification {
        return Notification.Builder(context)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(smallIcon)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .build()
    }
}
