package com.cribcall.cribcall

import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.SocketException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/**
 * WebSocket server with HTTP endpoint support, running over mTLS.
 * Handles the control protocol for monitor-listener communication.
 */
class ControlWebSocketServer(
    private val port: Int,
    private val tlsManager: MonitorTlsManager,
    private val onClientConnected: (connectionId: String, fingerprint: String, remoteAddress: String) -> Unit,
    private val onClientDisconnected: (connectionId: String, reason: String?) -> Unit,
    private val onWsMessage: (connectionId: String, messageJson: String) -> Unit,
    private val onHttpRequest: (method: String, path: String, fingerprint: String?, body: String?, responder: (Int, String?) -> Unit) -> Unit
) {
    companion object {
        private const val OPCODE_TEXT = 0x1
        private const val OPCODE_BINARY = 0x2
        private const val OPCODE_CLOSE = 0x8
        private const val OPCODE_PING = 0x9
        private const val OPCODE_PONG = 0xA
    }

    private val logTag = "cribcall_ws_server"

    private var serverSocket: SSLServerSocket? = null
    private var acceptThread: Thread? = null
    private val running = AtomicBoolean(false)
    private val connectionIdCounter = AtomicInteger(0)

    // Active WebSocket connections
    private val connections = ConcurrentHashMap<String, WebSocketConnection>()

    // Thread pool for handling connections
    private var executor: ExecutorService? = null

    val isRunning: Boolean get() = running.get()

    fun start() {
        if (running.get()) {
            Log.w(logTag, "Server already running")
            return
        }

        running.set(true)
        executor = Executors.newCachedThreadPool()

        serverSocket = tlsManager.createServerSocket(port)
        Log.i(logTag, "Server socket created on port $port")

        acceptThread = Thread({
            acceptLoop()
        }, "WS-Accept").apply { start() }

        Log.i(logTag, "Server started on port $port")
    }

    fun stop() {
        if (!running.getAndSet(false)) return

        Log.i(logTag, "Stopping server")

        // Close all connections
        connections.values.forEach { conn ->
            try {
                conn.close("server_shutdown")
            } catch (e: Exception) {
                Log.w(logTag, "Error closing connection: ${e.message}")
            }
        }
        connections.clear()

        // Close server socket
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            Log.w(logTag, "Error closing server socket: ${e.message}")
        }
        serverSocket = null

        // Shutdown executor
        executor?.shutdown()
        executor = null

        Log.i(logTag, "Server stopped")
    }

    /**
     * Broadcast a message to all connected WebSocket clients.
     * Dispatches to executor to avoid NetworkOnMainThreadException.
     */
    fun broadcast(messageJson: String) {
        executor?.execute {
            val frame = ControlMessageCodec.encodeFrame(messageJson)
            connections.values.forEach { conn ->
                try {
                    conn.sendFrame(frame)
                } catch (e: Exception) {
                    Log.w(logTag, "Broadcast to ${conn.connectionId} failed: ${e.message}")
                }
            }
        } ?: Log.w(logTag, "Broadcast failed: executor is null")
    }

    /**
     * Send a message to a specific connection.
     * Dispatches to executor to avoid NetworkOnMainThreadException.
     */
    fun sendTo(connectionId: String, messageJson: String) {
        val conn = connections[connectionId]
        if (conn == null) {
            Log.w(logTag, "Connection not found: $connectionId")
            return
        }
        if (conn.isClosed()) {
            Log.w(logTag, "Send to $connectionId skipped: already closed")
            return
        }
        // Dispatch to executor to avoid NetworkOnMainThreadException
        executor?.execute {
            try {
                val frame = ControlMessageCodec.encodeFrame(messageJson)
                conn.sendFrame(frame)
            } catch (e: Exception) {
                Log.w(logTag, "Send to $connectionId failed: ${e::class.simpleName}: ${e.message}")
                Log.w(logTag, "  closed=${conn.isClosed()}")
            }
        } ?: Log.w(logTag, "Send to $connectionId failed: executor is null")
    }

    /**
     * Disconnect all connections from a specific peer fingerprint.
     */
    fun disconnectByFingerprint(fingerprint: String) {
        connections.values.filter { it.fingerprint == fingerprint }.forEach { conn ->
            Log.i(logTag, "Disconnecting ${conn.connectionId} (peer removed)")
            conn.close("peer_removed")
        }
    }

    // -------------------------------------------------------------------------
    // Accept Loop
    // -------------------------------------------------------------------------

    private fun acceptLoop() {
        Log.i(logTag, "Accept loop started")
        while (running.get()) {
            try {
                val socket = serverSocket?.accept() as? SSLSocket
                if (socket != null) {
                    executor?.execute { handleConnection(socket) }
                }
            } catch (e: SocketException) {
                if (running.get()) {
                    Log.w(logTag, "Accept error: ${e.message}")
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.e(logTag, "Accept error: ${e.message}", e)
                }
            }
        }
        Log.i(logTag, "Accept loop exited")
    }

    // -------------------------------------------------------------------------
    // Connection Handling
    // -------------------------------------------------------------------------

    private fun handleConnection(socket: SSLSocket) {
        val remoteAddr = "${socket.inetAddress.hostAddress}:${socket.port}"
        Log.i(logTag, "New connection from $remoteAddr")

        try {
            // Start TLS handshake
            socket.startHandshake()

            // Validate client certificate
            val fingerprint = tlsManager.validateClientCert(socket)

            // Read HTTP request line
            val input = socket.inputStream
            val output = socket.outputStream
            val reader = BufferedReader(InputStreamReader(input))

            val requestLine = reader.readLine()
            if (requestLine == null) {
                Log.w(logTag, "Empty request from $remoteAddr")
                socket.close()
                return
            }

            val parts = requestLine.split(" ")
            if (parts.size < 2) {
                Log.w(logTag, "Invalid request line from $remoteAddr: $requestLine")
                sendHttpError(output, 400, "Bad Request")
                socket.close()
                return
            }

            val method = parts[0]
            val path = parts[1]
            Log.i(logTag, "Request: $method $path from $remoteAddr fp=${fingerprint?.take(12)}")

            // Read headers
            val headers = mutableMapOf<String, String>()
            var line: String?
            while (true) {
                line = reader.readLine()
                if (line.isNullOrEmpty()) break
                val colonIdx = line.indexOf(':')
                if (colonIdx > 0) {
                    val key = line.substring(0, colonIdx).trim().lowercase()
                    val value = line.substring(colonIdx + 1).trim()
                    headers[key] = value
                }
            }

            // Read body if present
            val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
            val body = if (contentLength > 0) {
                val bodyBytes = ByteArray(contentLength)
                var read = 0
                while (read < contentLength) {
                    val n = input.read(bodyBytes, read, contentLength - read)
                    if (n < 0) break
                    read += n
                }
                String(bodyBytes, Charsets.UTF_8)
            } else null

            // Route request
            when {
                path == "/control/ws" && isWebSocketUpgrade(headers) -> {
                    handleWebSocketUpgrade(socket, input, output, headers, fingerprint, remoteAddr)
                }
                path == "/health" -> {
                    sendHttpResponse(output, 200, """{"status":"ok"}""")
                    try {
                        socket.shutdownOutput()
                    } catch (_: Exception) {}
                    try {
                        socket.close()
                    } catch (_: Exception) {}
                }
                path == "/noise/subscribe" || path == "/noise/unsubscribe" -> {
                    // These endpoints require a body; if content-length is missing
                    // reject early with a 400 to avoid hanging the socket.
                    val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                    if (contentLength <= 0) {
                        sendHttpResponse(output, 400, """{"error":"missing_content_length"}""")
                        try {
                            socket.shutdownOutput()
                        } catch (_: Exception) {}
                        try {
                            socket.close()
                        } catch (_: Exception) {}
                    } else {
                        handleHttpRequest(socket, output, method, path, fingerprint, body)
                    }
                }
                else -> {
                    handleHttpRequest(socket, output, method, path, fingerprint, body)
                }
            }
        } catch (e: Exception) {
            Log.w(logTag, "Connection error from $remoteAddr: ${e.message}")
            try { socket.close() } catch (_: Exception) {}
        }
    }

    // -------------------------------------------------------------------------
    // HTTP Request Handling
    // -------------------------------------------------------------------------

    private fun handleHttpRequest(
        socket: SSLSocket,
        output: OutputStream,
        method: String,
        path: String,
        fingerprint: String?,
        body: String?
    ) {
        // Delegate to Dart for business logic via callback
        // Response callback may be invoked from main thread, so dispatch I/O to executor
        onHttpRequest(method, path, fingerprint, body) { statusCode, responseBody ->
            executor?.execute {
                try {
                    sendHttpResponse(output, statusCode, responseBody)
                } catch (e: Exception) {
                    Log.w(logTag, "Error sending HTTP response: ${e.message}")
                } finally {
                    try { socket.shutdownOutput() } catch (_: Exception) {}
                    try { socket.close() } catch (_: Exception) {}
                }
            } ?: run {
                Log.w(logTag, "HTTP response failed: executor is null")
                try { socket.close() } catch (_: Exception) {}
            }
        }
    }

    private fun sendHttpResponse(output: OutputStream, statusCode: Int, body: String?) {
        val statusText = when (statusCode) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            503 -> "Service Unavailable"
            else -> "Unknown"
        }

        val bodyBytes = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)

        val response = StringBuilder()
        response.append("HTTP/1.1 $statusCode $statusText\r\n")
        response.append("Content-Type: application/json\r\n")
        response.append("Content-Length: ${bodyBytes.size}\r\n")
        response.append("Cache-Control: no-store\r\n")
        response.append("Connection: close\r\n")
        response.append("\r\n")

        output.write(response.toString().toByteArray(Charsets.UTF_8))
        if (bodyBytes.isNotEmpty()) {
            output.write(bodyBytes)
        }
        output.flush()
    }

    private fun sendHttpError(output: OutputStream, statusCode: Int, message: String) {
        sendHttpResponse(output, statusCode, """{"error":"$message"}""")
    }

    // -------------------------------------------------------------------------
    // WebSocket Upgrade
    // -------------------------------------------------------------------------

    private fun isWebSocketUpgrade(headers: Map<String, String>): Boolean {
        return headers["upgrade"]?.lowercase() == "websocket" &&
               headers["connection"]?.lowercase()?.contains("upgrade") == true
    }

    private fun handleWebSocketUpgrade(
        socket: SSLSocket,
        input: InputStream,
        output: OutputStream,
        headers: Map<String, String>,
        fingerprint: String?,
        remoteAddr: String
    ) {
        // Require valid client certificate for WebSocket
        if (fingerprint == null) {
            Log.w(logTag, "WebSocket rejected: no valid client certificate")
            sendHttpError(output, 401, "client_certificate_required")
            socket.close()
            return
        }

        // Check trust
        if (!tlsManager.isTrusted(fingerprint)) {
            Log.w(logTag, "WebSocket rejected: untrusted certificate ${fingerprint.take(12)}")
            sendHttpError(output, 403, "certificate_not_trusted")
            socket.close()
            return
        }

        // Complete WebSocket handshake
        val wsKey = headers["sec-websocket-key"]
        if (wsKey == null) {
            Log.w(logTag, "WebSocket rejected: missing Sec-WebSocket-Key")
            sendHttpError(output, 400, "missing_websocket_key")
            socket.close()
            return
        }

        val acceptKey = computeWebSocketAccept(wsKey)
        val upgradeResponse = """
            HTTP/1.1 101 Switching Protocols
            Upgrade: websocket
            Connection: Upgrade
            Sec-WebSocket-Accept: $acceptKey

        """.trimIndent().replace("\n", "\r\n") + "\r\n"

        output.write(upgradeResponse.toByteArray(Charsets.UTF_8))
        output.flush()

        // Create connection
        val connectionId = "ws-${connectionIdCounter.incrementAndGet()}"
        val connection = WebSocketConnection(
            connectionId = connectionId,
            fingerprint = fingerprint,
            remoteAddress = remoteAddr,
            socket = socket,
            input = input,
            output = output,
            onMessage = { msg -> onWsMessage(connectionId, msg) },
            onClose = { reason ->
                connections.remove(connectionId)
                onClientDisconnected(connectionId, reason)
            }
        )

        connections[connectionId] = connection
        onClientConnected(connectionId, fingerprint, remoteAddr)

        // Start reading WebSocket frames
        connection.startReading()
    }

    private fun computeWebSocketAccept(key: String): String {
        val magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val digest = MessageDigest.getInstance("SHA-1")
        val hash = digest.digest((key + magic).toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(hash)
    }

    // -------------------------------------------------------------------------
    // WebSocket Connection
    // -------------------------------------------------------------------------

    inner class WebSocketConnection(
        val connectionId: String,
        val fingerprint: String,
        val remoteAddress: String,
        private val socket: SSLSocket,
        private val input: InputStream,
        private val output: OutputStream,
        private val onMessage: (String) -> Unit,
        private val onClose: (String?) -> Unit
    ) {
        private val closed = AtomicBoolean(false)
        private val outputLock = Any()

        fun isClosed(): Boolean = closed.get()

        fun startReading() {
            executor?.execute { readLoop() }
        }

        private fun readLoop() {
            val decoder = ControlMessageCodec.FrameDecoder()
            try {
                while (!closed.get() && running.get()) {
                    val frame = readWebSocketFrame() ?: break

                    when (frame.opcode) {
                        OPCODE_TEXT, OPCODE_BINARY -> {
                            // Decode length-prefixed JSON messages
                            val messages = decoder.addChunk(frame.payload)
                            for (msg in messages) {
                                onMessage(msg)
                            }
                        }
                        OPCODE_CLOSE -> {
                            Log.i(logTag, "WebSocket close frame received: $connectionId")
                            break
                        }
                        OPCODE_PING -> {
                            sendPong(frame.payload)
                        }
                        OPCODE_PONG -> {
                            // Ignore pong
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

        private fun readWebSocketFrame(): WebSocketFrame? {
            val b1 = input.read()
            if (b1 < 0) return null
            val b2 = input.read()
            if (b2 < 0) return null

            val fin = (b1 and 0x80) != 0
            val opcode = b1 and 0x0F
            val masked = (b2 and 0x80) != 0
            var payloadLen = (b2 and 0x7F).toLong()

            // Extended payload length
            if (payloadLen == 126L) {
                val lenBytes = ByteArray(2)
                if (input.read(lenBytes) != 2) return null
                payloadLen = (((lenBytes[0].toInt() and 0xFF) shl 8) or
                    (lenBytes[1].toInt() and 0xFF)).toLong()
            } else if (payloadLen == 127L) {
                val lenBytes = ByteArray(8)
                if (input.read(lenBytes) != 8) return null
                payloadLen = ByteBuffer.wrap(lenBytes).getLong()
            }

            // Masking key (if present)
            val maskKey = if (masked) {
                val key = ByteArray(4)
                if (input.read(key) != 4) return null
                key
            } else null

            // Payload
            if (payloadLen > 10_000_000) {
                Log.w(logTag, "Payload too large: $payloadLen")
                return null
            }
            val payload = ByteArray(payloadLen.toInt())
            var read = 0
            while (read < payloadLen) {
                val n = input.read(payload, read, (payloadLen - read).toInt())
                if (n < 0) return null
                read += n
            }

            // Unmask if needed
            if (maskKey != null) {
                for (i in payload.indices) {
                    payload[i] = (payload[i].toInt() xor maskKey[i % 4].toInt()).toByte()
                }
            }

            return WebSocketFrame(fin, opcode, payload)
        }

        fun sendFrame(payload: ByteArray) {
            synchronized(outputLock) {
                if (closed.get()) return

                // Send as binary frame (no masking for server->client)
                val header = ByteArray(if (payload.size < 126) 2 else if (payload.size <= 65535) 4 else 10)
                header[0] = (0x80 or OPCODE_BINARY).toByte() // FIN + Binary

                if (payload.size < 126) {
                    header[1] = payload.size.toByte()
                } else if (payload.size <= 65535) {
                    header[1] = 126.toByte()
                    header[2] = (payload.size shr 8).toByte()
                    header[3] = payload.size.toByte()
                } else {
                    header[1] = 127.toByte()
                    val len = payload.size.toLong()
                    for (i in 0..7) {
                        header[2 + i] = (len shr (56 - i * 8)).toByte()
                    }
                }

                output.write(header)
                output.write(payload)
                output.flush()
            }
        }

        private fun sendPong(payload: ByteArray) {
            synchronized(outputLock) {
                if (closed.get()) return
                val header = byteArrayOf(
                    (0x80 or OPCODE_PONG).toByte(),
                    payload.size.toByte()
                )
                output.write(header)
                output.write(payload)
                output.flush()
            }
        }

        fun close(reason: String?) {
            if (!closed.getAndSet(true)) {
                try {
                // Send close frame
                synchronized(outputLock) {
                    val closeFrame = byteArrayOf(
                        (0x80 or OPCODE_CLOSE).toByte(),
                        0.toByte()
                    )
                        output.write(closeFrame)
                        output.flush()
                    }
                } catch (_: Exception) {}

                try { socket.close() } catch (_: Exception) {}
                onClose(reason)
            }
        }

    }

    private data class WebSocketFrame(
        val fin: Boolean,
        val opcode: Int,
        val payload: ByteArray
    )
}
