package com.cribcall.cribcall

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

/**
 * Represents an active WebSocket connection.
 * Handles frame reading/writing and connection lifecycle.
 */
class WebSocketConnection(
    val connectionId: String,
    val fingerprint: String,
    val remoteAddress: String,
    private val socket: SSLSocket,
    private val input: InputStream,
    private val output: OutputStream,
    private val executor: ExecutorService?,
    private val onMessage: (String) -> Unit,
    private val onClose: (String?) -> Unit,
    private val isServerRunning: () -> Boolean
) {
    private val logTag = "cribcall_ws_conn"
    private val closed = AtomicBoolean(false)
    private val outputLock = Any()

    fun isClosed(): Boolean = closed.get()

    /**
     * Start reading frames in a background thread.
     */
    fun startReading() {
        executor?.execute { readLoop() }
    }

    private fun readLoop() {
        val decoder = ControlMessageCodec.FrameDecoder()
        try {
            while (!closed.get() && isServerRunning()) {
                val frame = WebSocketFrameCodec.readFrame(input) ?: break

                when (frame.opcode) {
                    WebSocketFrameCodec.OPCODE_TEXT,
                    WebSocketFrameCodec.OPCODE_BINARY -> {
                        // Decode length-prefixed JSON messages
                        val messages = decoder.addChunk(frame.payload)
                        for (msg in messages) {
                            onMessage(msg)
                        }
                    }
                    WebSocketFrameCodec.OPCODE_CLOSE -> {
                        Log.i(logTag, "Close frame received: $connectionId")
                        break
                    }
                    WebSocketFrameCodec.OPCODE_PING -> {
                        sendPong(frame.payload)
                    }
                    WebSocketFrameCodec.OPCODE_PONG -> {
                        // Ignore pong frames
                    }
                }
            }
        } catch (e: Exception) {
            if (!closed.get()) {
                Log.w(logTag, "Read error on $connectionId: ${e.message}")
            }
        }
        close(null)
    }

    /**
     * Send a pre-encoded frame (already includes length prefix).
     */
    fun sendFrame(payload: ByteArray) {
        synchronized(outputLock) {
            if (closed.get()) return
            WebSocketFrameCodec.writeBinaryFrame(output, payload)
        }
    }

    private fun sendPong(payload: ByteArray) {
        synchronized(outputLock) {
            if (closed.get()) return
            WebSocketFrameCodec.writePongFrame(output, payload)
        }
    }

    /**
     * Close the connection with an optional reason.
     */
    fun close(reason: String?) {
        if (!closed.getAndSet(true)) {
            try {
                synchronized(outputLock) {
                    WebSocketFrameCodec.writeCloseFrame(output)
                }
            } catch (_: Exception) {}

            try { socket.close() } catch (_: Exception) {}
            onClose(reason)
        }
    }
}
