package com.cribcall.cribcall

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.concurrent.thread

/**
 * Service for playing raw PCM audio received via WebRTC data channel.
 * Audio format: 16-bit signed little-endian mono at 16kHz.
 */
class AudioPlaybackService {
    companion object {
        private const val TAG = "AudioPlayback"
        private const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioTrack: AudioTrack? = null
    private var playbackThread: Thread? = null
    private var isPlaying = false
    private val audioQueue = ConcurrentLinkedQueue<ByteArray>()
    private var volume = 1.0f

    fun start(): Boolean {
        if (isPlaying) return true

        try {
            val bufferSize = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
            if (bufferSize == AudioTrack.ERROR || bufferSize == AudioTrack.ERROR_BAD_VALUE) {
                Log.e(TAG, "Failed to get min buffer size")
                return false
            }

            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val audioFormat = AudioFormat.Builder()
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(CHANNEL_CONFIG)
                .setEncoding(AUDIO_FORMAT)
                .build()

            audioTrack = AudioTrack.Builder()
                .setAudioAttributes(audioAttributes)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize * 4)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            audioTrack?.setVolume(volume.coerceIn(0f, 2f))
            isPlaying = true
            audioTrack?.play()

            playbackThread = thread(start = true, name = "AudioPlaybackThread") {
                playbackLoop()
            }

            Log.d(TAG, "Audio playback started")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start audio playback: ${e.message}")
            stop()
            return false
        }
    }

    fun stop() {
        isPlaying = false
        playbackThread?.interrupt()
        playbackThread = null

        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio track: ${e.message}")
        }
        audioTrack = null
        audioQueue.clear()

        Log.d(TAG, "Audio playback stopped")
    }

    fun setVolume(volume: Float) {
        this.volume = volume.coerceIn(0f, 2f)
        audioTrack?.setVolume(this.volume)
    }

    fun write(data: ByteArray) {
        if (!isPlaying) return
        audioQueue.offer(data)
    }

    private fun playbackLoop() {
        val silence = ByteArray(640) // 20ms of silence at 16kHz mono 16-bit

        while (isPlaying && !Thread.currentThread().isInterrupted) {
            try {
                val data = audioQueue.poll()
                if (data != null) {
                    audioTrack?.write(data, 0, data.size)
                } else {
                    // No data available, write silence to prevent underrun
                    audioTrack?.write(silence, 0, silence.size)
                    Thread.sleep(10)
                }
            } catch (e: InterruptedException) {
                break
            } catch (e: Exception) {
                Log.e(TAG, "Playback error: ${e.message}")
            }
        }
    }
}
