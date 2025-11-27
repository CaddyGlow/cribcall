package com.cribcall.cribcall

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class AudioCaptureService : Service() {
    private val binder = LocalBinder()
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private val logTag = "cribcall_audio_svc"
    private val audioSampleRate = 16000
    private val audioChannelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private var audioBufferSize = 0

    // Callback for sending audio data to Flutter
    var onAudioData: ((ByteArray) -> Unit)? = null
    private var packetCount = 0

    companion object {
        const val CHANNEL_ID = "cribcall_monitoring"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.cribcall.START_CAPTURE"
        const val ACTION_STOP = "com.cribcall.STOP_CAPTURE"
    }

    inner class LocalBinder : Binder() {
        fun getService(): AudioCaptureService = this@AudioCaptureService
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.i(logTag, "AudioCaptureService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForegroundWithNotification()
                startAudioCapture()
            }
            ACTION_STOP -> {
                stopAudioCapture()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopAudioCapture()
        Log.i(logTag, "AudioCaptureService destroyed")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Baby Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when CribCall is monitoring for sounds"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
            Log.i(logTag, "Notification channel created")
        }
    }

    private fun startForegroundWithNotification() {
        val notificationIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, AudioCaptureService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }.apply {
            setContentTitle("CribCall Monitoring")
            setContentText("Listening for sounds...")
            setSmallIcon(android.R.drawable.ic_btn_speak_now)
            setContentIntent(pendingIntent)
            setOngoing(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                addAction(
                    Notification.Action.Builder(
                        null,
                        "Stop",
                        stopPendingIntent
                    ).build()
                )
            }
        }.build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        Log.i(logTag, "Foreground notification started")
    }

    private fun startAudioCapture() {
        if (isRecording) {
            Log.w(logTag, "Already recording")
            return
        }

        audioBufferSize = AudioRecord.getMinBufferSize(
            audioSampleRate,
            audioChannelConfig,
            audioFormat
        )
        if (audioBufferSize == AudioRecord.ERROR || audioBufferSize == AudioRecord.ERROR_BAD_VALUE) {
            Log.e(logTag, "Invalid buffer size: $audioBufferSize")
            return
        }

        audioBufferSize = maxOf(audioBufferSize, 640)

        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                audioSampleRate,
                audioChannelConfig,
                audioFormat,
                audioBufferSize * 2
            )
        } catch (e: SecurityException) {
            Log.e(logTag, "SecurityException creating AudioRecord: ${e.message}")
            return
        }

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(logTag, "AudioRecord failed to initialize")
            audioRecord?.release()
            audioRecord = null
            return
        }

        isRecording = true
        audioRecord?.startRecording()
        Log.i(logTag, "Started audio capture, bufferSize=$audioBufferSize")

        thread(name = "AudioCaptureThread") {
            val buffer = ShortArray(audioBufferSize / 2)
            val handler = Handler(Looper.getMainLooper())

            while (isRecording) {
                val readResult = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (readResult > 0) {
                    val byteBuffer = ByteBuffer.allocate(readResult * 2)
                    byteBuffer.order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until readResult) {
                        byteBuffer.putShort(buffer[i])
                    }
                    val bytes = byteBuffer.array()

                    handler.post {
                        packetCount++
                        if (packetCount == 1 || packetCount % 100 == 0) {
                            Log.i(logTag, "Audio packet #$packetCount (${bytes.size} bytes), callback=${onAudioData != null}")
                        }
                        onAudioData?.invoke(bytes)
                    }
                } else if (readResult < 0) {
                    Log.e(logTag, "AudioRecord read error: $readResult")
                    break
                }
            }
            Log.i(logTag, "Audio capture thread exiting")
        }
    }

    private fun stopAudioCapture() {
        if (!isRecording) return

        isRecording = false
        try {
            audioRecord?.stop()
        } catch (e: Exception) {
            Log.w(logTag, "Error stopping AudioRecord: ${e.message}")
        }
        audioRecord?.release()
        audioRecord = null
        Log.i(logTag, "Stopped audio capture")
    }

    fun isCapturing(): Boolean = isRecording
}
