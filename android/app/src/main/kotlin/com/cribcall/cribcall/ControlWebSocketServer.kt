package com.cribcall.cribcall

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.SocketException
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
 *
 * Extracted components:
 * - [WebSocketFrameCodec] - Low-level WebSocket frame encoding/decoding
 * - [WebSocketConnection] - Individual connection handling
 * - [HttpResponseWriter] - HTTP response utilities
 */
class ControlWebSocketServer(
    private val port: Int,
    private val tlsManager: MonitorTlsManager,
    private val onClientConnected: (connectionId: String, fingerprint: String, remoteAddress: String) -> Unit,
    private val onClientDisconnected: (connectionId: String, reason: String?) -> Unit,
    private val onWsMessage: (connectionId: String, messageJson: String) -> Unit,
    private val onHttpRequest: (method: String, path: String, fingerprint: String?, body: String?, responder: (Int, String?) -> Unit) -> Unit
) {
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

            // Read HTTP request
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
                HttpResponseWriter.sendError(output, 400, "Bad Request")
                socket.close()
                return
            }

            val method = parts[0]
            val path = parts[1]
            Log.i(logTag, "Request: $method $path from $remoteAddr fp=${fingerprint?.take(12)}")

            // Read headers
            val headers = readHeaders(reader)

            // Read body if present (must read from BufferedReader, not raw input,
            // because BufferedReader may have already consumed body bytes)
            val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
            val body = readBody(reader, contentLength)

            // Route request
            routeRequest(socket, input, output, method, path, headers, fingerprint, body, remoteAddr)
        } catch (e: Exception) {
            Log.w(logTag, "Connection error from $remoteAddr: ${e.message}")
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun readHeaders(reader: BufferedReader): Map<String, String> {
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
        return headers
    }

    private fun readBody(reader: BufferedReader, contentLength: Int): String? {
        if (contentLength <= 0) return null

        val bodyChars = CharArray(contentLength)
        var read = 0
        while (read < contentLength) {
            val n = reader.read(bodyChars, read, contentLength - read)
            if (n < 0) break
            read += n
        }
        return String(bodyChars, 0, read)
    }

    private fun routeRequest(
        socket: SSLSocket,
        input: java.io.InputStream,
        output: OutputStream,
        method: String,
        path: String,
        headers: Map<String, String>,
        fingerprint: String?,
        body: String?,
        remoteAddr: String
    ) {
        when {
            path == "/control/ws" && isWebSocketUpgrade(headers) -> {
                handleWebSocketUpgrade(socket, input, output, headers, fingerprint, remoteAddr)
            }
            path == "/health" -> {
                HttpResponseWriter.sendResponse(output, 200, """{"status":"ok"}""")
                closeSocket(socket)
            }
            path == "/noise/subscribe" || path == "/noise/unsubscribe" -> {
                val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                if (contentLength <= 0) {
                    HttpResponseWriter.sendResponse(output, 400, """{"error":"missing_content_length"}""")
                    closeSocket(socket)
                } else {
                    handleHttpRequest(socket, output, method, path, fingerprint, body)
                }
            }
            else -> {
                handleHttpRequest(socket, output, method, path, fingerprint, body)
            }
        }
    }

    private fun closeSocket(socket: SSLSocket) {
        try { socket.shutdownOutput() } catch (_: Exception) {}
        try { socket.close() } catch (_: Exception) {}
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
        onHttpRequest(method, path, fingerprint, body) { statusCode, responseBody ->
            executor?.execute {
                try {
                    HttpResponseWriter.sendResponse(output, statusCode, responseBody)
                } catch (e: Exception) {
                    Log.w(logTag, "Error sending HTTP response: ${e.message}")
                } finally {
                    closeSocket(socket)
                }
            } ?: run {
                Log.w(logTag, "HTTP response failed: executor is null")
                try { socket.close() } catch (_: Exception) {}
            }
        }
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
        input: java.io.InputStream,
        output: OutputStream,
        headers: Map<String, String>,
        fingerprint: String?,
        remoteAddr: String
    ) {
        // Require valid client certificate for WebSocket
        if (fingerprint == null) {
            Log.w(logTag, "WebSocket rejected: no valid client certificate")
            HttpResponseWriter.sendError(output, 401, "client_certificate_required")
            socket.close()
            return
        }

        // Check trust
        if (!tlsManager.isTrusted(fingerprint)) {
            Log.w(logTag, "WebSocket rejected: untrusted certificate ${fingerprint.take(12)}")
            HttpResponseWriter.sendError(output, 403, "certificate_not_trusted")
            socket.close()
            return
        }

        // Complete WebSocket handshake
        val wsKey = headers["sec-websocket-key"]
        if (wsKey == null) {
            Log.w(logTag, "WebSocket rejected: missing Sec-WebSocket-Key")
            HttpResponseWriter.sendError(output, 400, "missing_websocket_key")
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
            executor = executor,
            onMessage = { msg -> onWsMessage(connectionId, msg) },
            onClose = { reason ->
                connections.remove(connectionId)
                onClientDisconnected(connectionId, reason)
            },
            isServerRunning = { running.get() }
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
}
