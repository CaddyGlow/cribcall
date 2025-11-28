package com.cribcall.cribcall

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Foreground service for the Listener role.
 * Keeps the app alive to maintain WebSocket connection with the Monitor.
 */
class ListenerService : Service() {

    companion object {
        const val ACTION_START = "com.cribcall.listener.START"
        const val ACTION_STOP = "com.cribcall.listener.STOP"
        const val NOTIFICATION_ID = 2002
        private const val TAG = "cribcall_listener"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createNotificationChannels(this)
        Log.i(TAG, "ListenerService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val monitorName = intent.getStringExtra("monitorName") ?: "Monitor"
                startForegroundWithNotification(monitorName)
                acquireWakeLock()
                Log.i(TAG, "ListenerService started for monitor: $monitorName")
            }
            ACTION_STOP -> {
                Log.i(TAG, "ListenerService stopping")
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWakeLock()
        Log.i(TAG, "ListenerService destroyed")
        super.onDestroy()
    }

    private fun startForegroundWithNotification(monitorName: String) {
        val notification = NotificationHelper.buildForegroundNotification(
            context = this,
            channelId = NotificationHelper.CHANNEL_ID_LISTENER,
            title = "CribCall Listening",
            text = "Connected to $monitorName",
            serviceClass = ListenerService::class.java,
            stopAction = ACTION_STOP,
            notificationId = NOTIFICATION_ID,
            smallIcon = android.R.drawable.ic_dialog_info
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "CribCall::ListenerWakeLock"
            ).apply {
                acquire(10 * 60 * 1000L) // 10 minutes max, will be refreshed
            }
            Log.i(TAG, "WakeLock acquired")
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.i(TAG, "WakeLock released")
            }
        }
        wakeLock = null
    }
}
