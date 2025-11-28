package com.cribcall.cribcall

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Foreground service hosting the mTLS WebSocket control server.
 * Survives app backgrounding for long baby monitor sessions.
 *
 * Architecture: Kotlin handles networking (TLS termination, WebSocket framing),
 * Dart handles all business logic via platform channels.
 */
class MonitorService : Service() {
    private val binder = LocalBinder()
    private val logTag = "cribcall_monitor_svc"

    // Server components
    private var tlsManager: MonitorTlsManager? = null
    private var webSocketServer: ControlWebSocketServer? = null
    private var serverPort: Int? = null

    // Event callbacks (set by MainActivity via binding)
    var onServerStarted: ((Int) -> Unit)? = null
    var onServerError: ((String) -> Unit)? = null
    var onClientConnected: ((String, String, String) -> Unit)? = null  // connectionId, fingerprint, remoteAddress
    var onClientDisconnected: ((String, String?) -> Unit)? = null  // connectionId, reason
    var onWsMessage: ((String, String) -> Unit)? = null  // connectionId, messageJson
    var onHttpRequest: ((String, String, String, String?, String?) -> Unit)? = null  // requestId, method, path, fingerprint, bodyJson

    // Pending HTTP requests awaiting Dart response
    private val pendingHttpRequests = ConcurrentHashMap<String, HttpRequestContext>()
    private val requestIdCounter = AtomicInteger(0)

    companion object {
        const val NOTIFICATION_ID = 1002
        const val ACTION_START = "com.cribcall.MONITOR_START"
        const val ACTION_STOP = "com.cribcall.MONITOR_STOP"

        // Intent extras for start
        const val EXTRA_PORT = "port"
        const val EXTRA_IDENTITY_JSON = "identityJson"
        const val EXTRA_TRUSTED_PEERS_JSON = "trustedPeersJson"
    }

    inner class LocalBinder : Binder() {
        fun getService(): MonitorService = this@MonitorService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createNotificationChannels(this)
        Log.i(logTag, "MonitorService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val port = intent.getIntExtra(EXTRA_PORT, 48080)
                val identityJson = intent.getStringExtra(EXTRA_IDENTITY_JSON)
                val trustedPeersJson = intent.getStringExtra(EXTRA_TRUSTED_PEERS_JSON)

                if (identityJson == null) {
                    Log.e(logTag, "Missing identity JSON for ACTION_START")
                    onServerError?.invoke("Missing identity configuration")
                    stopSelf()
                    return START_NOT_STICKY
                }

                startForegroundWithNotification()
                startServer(port, identityJson, trustedPeersJson ?: "[]")
            }
            ACTION_STOP -> {
                stopServer()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopServer()
        Log.i(logTag, "MonitorService destroyed")
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        val notification = NotificationHelper.buildForegroundNotification(
            context = this,
            channelId = NotificationHelper.CHANNEL_ID_CONTROL_SERVER,
            title = "CribCall Server",
            text = "Control server running",
            serviceClass = MonitorService::class.java,
            stopAction = ACTION_STOP,
            notificationId = NOTIFICATION_ID,
            smallIcon = android.R.drawable.ic_menu_share
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        Log.i(logTag, "Foreground notification started")
    }

    // -------------------------------------------------------------------------
    // Server Lifecycle
    // -------------------------------------------------------------------------

    private fun startServer(port: Int, identityJson: String, trustedPeersJson: String) {
        try {
            Log.i(logTag, "Starting server on port $port")

            // Parse identity
            val identity = parseIdentity(identityJson)

            // Parse trusted peers
            val trustedPeers = parseTrustedPeers(trustedPeersJson)

            // Initialize TLS manager
            tlsManager = MonitorTlsManager(
                serverCertDer = identity.certDer,
                serverPrivateKey = identity.privateKey,
                trustedPeerCerts = trustedPeers.mapNotNull { it.certDer }
            )

            // Initialize WebSocket server
            webSocketServer = ControlWebSocketServer(
                port = port,
                tlsManager = tlsManager!!,
                onClientConnected = { connId, fingerprint, addr ->
                    Log.i(logTag, "Client connected: $connId fp=${fingerprint.take(12)}")
                    onClientConnected?.invoke(connId, fingerprint, addr)
                },
                onClientDisconnected = { connId, reason ->
                    Log.i(logTag, "Client disconnected: $connId reason=$reason")
                    onClientDisconnected?.invoke(connId, reason)
                },
                onWsMessage = { connId, message ->
                    Log.d(logTag, "WS message from $connId: ${message.take(100)}")
                    onWsMessage?.invoke(connId, message)
                },
                onHttpRequest = { method, path, fingerprint, body, responder ->
                    val requestId = "req-${requestIdCounter.incrementAndGet()}"
                    Log.i(logTag, "HTTP request $requestId: $method $path fp=${fingerprint?.take(12)}")
                    pendingHttpRequests[requestId] = HttpRequestContext(responder)
                    onHttpRequest?.invoke(requestId, method, path, fingerprint, body)
                }
            )

            webSocketServer?.start()
            serverPort = port

            Log.i(logTag, "Server started on port $port")
            onServerStarted?.invoke(port)

        } catch (e: Exception) {
            Log.e(logTag, "Server start failed: ${e.message}", e)
            onServerError?.invoke(e.message ?: "Unknown error")
            stopServer()
        }
    }

    private fun stopServer() {
        Log.i(logTag, "Stopping server")
        try {
            webSocketServer?.stop()
        } catch (e: Exception) {
            Log.w(logTag, "Error stopping WebSocket server: ${e.message}")
        }
        webSocketServer = null
        tlsManager = null
        serverPort = null
        pendingHttpRequests.clear()
    }

    // -------------------------------------------------------------------------
    // Public API (called from MainActivity via binding)
    // -------------------------------------------------------------------------

    fun isRunning(): Boolean = webSocketServer?.isRunning == true

    fun getPort(): Int? = serverPort

    /**
     * Add a trusted peer certificate dynamically.
     */
    fun addTrustedPeer(peerJson: String) {
        try {
            val peer = parseTrustedPeer(JSONObject(peerJson))
            if (peer.certDer != null) {
                tlsManager?.addTrustedCert(peer.certDer)
                Log.i(logTag, "Added trusted peer: ${peer.fingerprint.take(12)}")
            }
        } catch (e: Exception) {
            Log.e(logTag, "Failed to add trusted peer: ${e.message}")
        }
    }

    /**
     * Remove a trusted peer by fingerprint.
     */
    fun removeTrustedPeer(fingerprint: String) {
        try {
            tlsManager?.removeTrustedCert(fingerprint)
            // Also disconnect any active connections from this peer
            webSocketServer?.disconnectByFingerprint(fingerprint)
            Log.i(logTag, "Removed trusted peer: ${fingerprint.take(12)}")
        } catch (e: Exception) {
            Log.e(logTag, "Failed to remove trusted peer: ${e.message}")
        }
    }

    /**
     * Broadcast a message to all connected WebSocket clients.
     */
    fun broadcast(messageJson: String) {
        webSocketServer?.broadcast(messageJson)
    }

    /**
     * Send a message to a specific WebSocket connection.
     */
    fun sendTo(connectionId: String, messageJson: String) {
        webSocketServer?.sendTo(connectionId, messageJson)
    }

    /**
     * Respond to a pending HTTP request.
     */
    fun respondHttp(requestId: String, statusCode: Int, bodyJson: String?) {
        val context = pendingHttpRequests.remove(requestId)
        if (context != null) {
            context.responder(statusCode, bodyJson)
            Log.i(logTag, "HTTP response sent for $requestId: $statusCode")
        } else {
            Log.w(logTag, "No pending HTTP request found for $requestId")
        }
    }

    // -------------------------------------------------------------------------
    // Parsing helpers
    // -------------------------------------------------------------------------

    private data class IdentityData(
        val deviceId: String,
        val certDer: ByteArray,
        val privateKey: ByteArray,
        val fingerprint: String
    )

    private data class TrustedPeerData(
        val deviceId: String,
        val fingerprint: String,
        val certDer: ByteArray?
    )

    private fun parseIdentity(json: String): IdentityData {
        val obj = JSONObject(json)
        return IdentityData(
            deviceId = obj.getString("deviceId"),
            certDer = Base64.decode(obj.getString("certDer"), Base64.NO_WRAP),
            privateKey = Base64.decode(obj.getString("privateKey"), Base64.NO_WRAP),
            fingerprint = obj.getString("fingerprint")
        )
    }

    private fun parseTrustedPeers(json: String): List<TrustedPeerData> {
        val arr = JSONArray(json)
        return (0 until arr.length()).map { i ->
            parseTrustedPeer(arr.getJSONObject(i))
        }
    }

    private fun parseTrustedPeer(obj: JSONObject): TrustedPeerData {
        val certDerStr = obj.optString("certDer", "")
        return TrustedPeerData(
            deviceId = obj.optString("deviceId", ""),
            fingerprint = obj.getString("fingerprint"),
            certDer = if (certDerStr.isNotEmpty()) Base64.decode(certDerStr, Base64.NO_WRAP) else null
        )
    }

    /**
     * Context for a pending HTTP request awaiting Dart response.
     */
    private class HttpRequestContext(
        val responder: (statusCode: Int, bodyJson: String?) -> Unit
    )
}
