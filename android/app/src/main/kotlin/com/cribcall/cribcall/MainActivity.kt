package com.cribcall.cribcall

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle

/**
 * Main activity for CribCall Flutter application.
 *
 * Handles platform channel communication between Flutter and Android native code,
 * including mDNS discovery, audio capture, and monitor server services.
 */
class MainActivity : FlutterActivity() {

    // -----------------------------------------------------------------------------
    // Channel names
    // -----------------------------------------------------------------------------
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private val deviceInfoChannel = "cribcall/device_info"
    private val audioChannel = "cribcall/audio"
    private val audioEvents = "cribcall/audio_events"
    private val listenerChannel = "cribcall/listener"
    private val audioPlaybackChannel = "cribcall/audio_playback"
    private val monitorServerChannel = "cribcall/monitor_server"
    private val monitorEventsChannel = "cribcall/monitor_events"

    // -----------------------------------------------------------------------------
    // Event sinks
    // -----------------------------------------------------------------------------
    private var mdnsEventSink: EventChannel.EventSink? = null
    private var audioEventSink: EventChannel.EventSink? = null
    private var monitorEventSink: EventChannel.EventSink? = null

    // -----------------------------------------------------------------------------
    // Managers and services
    // -----------------------------------------------------------------------------
    private var mdnsDiscoveryManager: MdnsDiscoveryManager? = null
    private var audioPlaybackService: AudioPlaybackService? = null
    private var audioCaptureService: AudioCaptureService? = null
    private var monitorService: MonitorService? = null

    // -----------------------------------------------------------------------------
    // Service binding state
    // -----------------------------------------------------------------------------
    private var audioServiceBound = false
    private var monitorServiceBound = false
    private var pendingMdnsParams: Map<*, *>? = null
    private var pendingAdvertiseStart = false

    // -----------------------------------------------------------------------------
    // Permission codes
    // -----------------------------------------------------------------------------
    private val RECORD_AUDIO_PERMISSION_CODE = 1001
    private val POST_NOTIFICATIONS_PERMISSION_CODE = 1002

    // -----------------------------------------------------------------------------
    // Logging
    // -----------------------------------------------------------------------------
    private val logTag = "cribcall_main"
    private val audioLogTag = "cribcall_audio"
    private val monitorLogTag = "cribcall_monitor"
    private val listenerLogTag = "cribcall_listener"

    // -----------------------------------------------------------------------------
    // Service connections
    // -----------------------------------------------------------------------------
    private val audioServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as AudioCaptureService.LocalBinder
            audioCaptureService = binder.getService()
            audioServiceBound = true
            Log.i(audioLogTag, "AudioCaptureService bound")

            // Forward audio data to Flutter
            audioCaptureService?.onAudioData = { bytes ->
                audioEventSink?.success(bytes)
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            audioCaptureService = null
            audioServiceBound = false
            Log.i(audioLogTag, "AudioCaptureService unbound")
        }
    }

    private val monitorServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as MonitorService.LocalBinder
            monitorService = binder.getService()
            monitorServiceBound = true
            Log.i(monitorLogTag, "MonitorService bound")
            setupMonitorServiceCallbacks()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            monitorService = null
            monitorServiceBound = false
            Log.i(monitorLogTag, "MonitorService unbound")
        }
    }

    // -----------------------------------------------------------------------------
    // Flutter engine configuration
    // -----------------------------------------------------------------------------
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Create notification channels
        NotificationHelper.createNotificationChannels(this)

        // Initialize mDNS discovery manager
        mdnsDiscoveryManager = MdnsDiscoveryManager(this) { event ->
            mdnsEventSink?.success(event)
        }

        // Bind to audio service early
        bindAudioService()

        // Set up all platform channels
        setupMdnsChannel(messenger)
        setupDeviceInfoChannel(messenger)
        setupAudioChannel(messenger)
        setupAudioEventsChannel(messenger)
        setupListenerChannel(messenger)
        setupAudioPlaybackChannel(messenger)
        setupMonitorServerChannel(messenger)
        setupMonitorEventsChannel(messenger)
    }

    // -----------------------------------------------------------------------------
    // Channel setup methods
    // -----------------------------------------------------------------------------

    private fun setupMdnsChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, mdnsChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertise" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        pendingMdnsParams = args
                        when (startAdvertiseService()) {
                            AdvertiseStartResult.STARTED -> result.success(null)
                            AdvertiseStartResult.DEFERRED -> result.error(
                                "foreground_service_not_allowed",
                                "Cannot start while app is in background.",
                                null
                            )
                            AdvertiseStartResult.FAILED -> result.error(
                                "service_start_failed",
                                "Failed to start advertise service.",
                                null
                            )
                        }
                    } else {
                        result.success(null)
                    }
                }
                "stop" -> {
                    stopMdns()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, mdnsEvents).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                mdnsEventSink = events
                mdnsDiscoveryManager?.startDiscovery()
            }
            override fun onCancel(arguments: Any?) {
                mdnsEventSink = null
                mdnsDiscoveryManager?.stopDiscovery()
            }
        })
    }

    private fun setupDeviceInfoChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, deviceInfoChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceName" -> result.success(resolveDeviceName())
                else -> result.notImplemented()
            }
        }
    }

    private fun setupAudioChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, audioChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> handleAudioStart(call, result)
                "stop" -> {
                    stopAudioCaptureService()
                    result.success(null)
                }
                "hasPermission" -> result.success(checkAudioPermission())
                "requestPermission" -> {
                    if (checkAudioPermission()) {
                        result.success(true)
                    } else {
                        requestAudioPermission()
                        result.success(false)
                    }
                }
                "isRunning" -> result.success(audioCaptureService?.isCapturing() == true)
                else -> result.notImplemented()
            }
        }
    }

    private fun setupAudioEventsChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        EventChannel(messenger, audioEvents).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioEventSink = events
                audioCaptureService?.onAudioData = { bytes ->
                    audioEventSink?.success(bytes)
                }
            }
            override fun onCancel(arguments: Any?) {
                audioEventSink = null
            }
        })
    }

    private fun setupListenerChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, listenerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val monitorName = call.argument<String>("monitorName") ?: "Monitor"
                    ensureNotificationPermission()
                    startListenerService(monitorName)
                    result.success(null)
                }
                "stop" -> {
                    stopListenerService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupAudioPlaybackChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, audioPlaybackChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (audioPlaybackService == null) {
                        audioPlaybackService = AudioPlaybackService()
                    }
                    result.success(audioPlaybackService?.start() == true)
                }
                "stop" -> {
                    audioPlaybackService?.stop()
                    audioPlaybackService = null
                    result.success(null)
                }
                "write" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data != null) {
                        audioPlaybackService?.write(data)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing audio data", null)
                    }
                }
                "setVolume" -> {
                    val volume = call.argument<Double>("volume") ?: 1.0
                    audioPlaybackService?.setVolume(volume.toFloat())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupMonitorServerChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, monitorServerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> handleMonitorServerStart(call, result)
                "stop" -> {
                    stopMonitorService()
                    result.success(null)
                }
                "addTrustedPeer" -> {
                    val peerJson = call.argument<String>("peerJson")
                    if (peerJson != null) {
                        monitorService?.addTrustedPeer(peerJson)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing peerJson", null)
                    }
                }
                "removeTrustedPeer" -> {
                    val fingerprint = call.argument<String>("fingerprint")
                    if (fingerprint != null) {
                        monitorService?.removeTrustedPeer(fingerprint)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing fingerprint", null)
                    }
                }
                "broadcast" -> {
                    val messageJson = call.argument<String>("messageJson")
                    if (messageJson != null) {
                        monitorService?.broadcast(messageJson)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing messageJson", null)
                    }
                }
                "sendTo" -> {
                    val connectionId = call.argument<String>("connectionId")
                    val messageJson = call.argument<String>("messageJson")
                    if (connectionId != null && messageJson != null) {
                        monitorService?.sendTo(connectionId, messageJson)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing connectionId or messageJson", null)
                    }
                }
                "respondHttp" -> {
                    val requestId = call.argument<String>("requestId")
                    val statusCode = call.argument<Int>("statusCode") ?: 200
                    val bodyJson = call.argument<String>("bodyJson")
                    if (requestId != null) {
                        monitorService?.respondHttp(requestId, statusCode, bodyJson)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Missing requestId", null)
                    }
                }
                "isRunning" -> result.success(monitorService?.isRunning() == true)
                "getPort" -> result.success(monitorService?.getPort())
                else -> result.notImplemented()
            }
        }
    }

    private fun setupMonitorEventsChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        EventChannel(messenger, monitorEventsChannel).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                monitorEventSink = events
                if (monitorServiceBound) {
                    setupMonitorServiceCallbacks()
                }
            }
            override fun onCancel(arguments: Any?) {
                monitorEventSink = null
            }
        })
    }

    // -----------------------------------------------------------------------------
    // Handler methods
    // -----------------------------------------------------------------------------

    private fun handleAudioStart(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (!checkAudioPermission()) {
            requestAudioPermission()
            result.error("permission_denied", "RECORD_AUDIO permission required", null)
            return
        }
        ensureNotificationPermission()

        val args = call.arguments as? Map<*, *>
        if (args != null && args.isNotEmpty()) {
            pendingMdnsParams = args
        }

        try {
            startAudioCaptureService()
            result.success(null)
        } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
            result.error(
                "foreground_service_not_allowed",
                "Cannot start while app is in background.",
                e.message
            )
        } catch (e: Exception) {
            result.error("service_start_failed", e.message, null)
        }
    }

    private fun handleMonitorServerStart(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val port = call.argument<Int>("port") ?: 48080
        val identityJson = call.argument<String>("identityJson")
        val trustedPeersJson = call.argument<String>("trustedPeersJson") ?: "[]"

        if (identityJson == null) {
            result.error("invalid_args", "Missing identityJson", null)
            return
        }

        ensureNotificationPermission()

        try {
            startMonitorService(port, identityJson, trustedPeersJson)
            result.success(null)
        } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
            result.error(
                "foreground_service_not_allowed",
                "Cannot start while app is in background.",
                e.message
            )
        } catch (e: Exception) {
            result.error("service_start_failed", e.message, null)
        }
    }

    // -----------------------------------------------------------------------------
    // Monitor service callbacks
    // -----------------------------------------------------------------------------

    private fun setupMonitorServiceCallbacks() {
        val handler = Handler(Looper.getMainLooper())

        monitorService?.onServerStarted = { port ->
            handler.post {
                monitorEventSink?.success(mapOf("event" to "serverStarted", "port" to port))
            }
        }

        monitorService?.onServerError = { error ->
            handler.post {
                monitorEventSink?.success(mapOf("event" to "serverError", "error" to error))
            }
        }

        monitorService?.onClientConnected = { connectionId, fingerprint, remoteAddress ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "clientConnected",
                    "connectionId" to connectionId,
                    "fingerprint" to fingerprint,
                    "remoteAddress" to remoteAddress
                ))
            }
        }

        monitorService?.onClientDisconnected = { connectionId, reason ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "clientDisconnected",
                    "connectionId" to connectionId,
                    "reason" to reason
                ))
            }
        }

        monitorService?.onWsMessage = { connectionId, messageJson ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "wsMessage",
                    "connectionId" to connectionId,
                    "message" to messageJson
                ))
            }
        }

        monitorService?.onHttpRequest = { requestId, method, path, fingerprint, bodyJson ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "httpRequest",
                    "requestId" to requestId,
                    "method" to method,
                    "path" to path,
                    "fingerprint" to fingerprint,
                    "body" to bodyJson
                ))
            }
        }
    }

    // -----------------------------------------------------------------------------
    // Service lifecycle methods
    // -----------------------------------------------------------------------------

    private fun bindAudioService() {
        val intent = Intent(this, AudioCaptureService::class.java)
        bindService(intent, audioServiceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun startAudioCaptureService() {
        Log.i(audioLogTag, "Starting audio capture foreground service")
        val intent = buildMdnsIntent(AudioCaptureService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopAudioCaptureService() {
        Log.i(audioLogTag, "Stopping audio capture service")
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_STOP
        }
        startService(intent)
    }

    private enum class AdvertiseStartResult { STARTED, DEFERRED, FAILED }

    private fun startAdvertiseService(): AdvertiseStartResult {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            pendingAdvertiseStart = true
            return AdvertiseStartResult.DEFERRED
        }

        val intent = buildMdnsIntent(AudioCaptureService.ACTION_ADVERTISE_ONLY)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            pendingAdvertiseStart = false
            AdvertiseStartResult.STARTED
        } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
            pendingAdvertiseStart = true
            AdvertiseStartResult.DEFERRED
        } catch (e: Exception) {
            pendingAdvertiseStart = false
            AdvertiseStartResult.FAILED
        }
    }

    private fun startMonitorService(port: Int, identityJson: String, trustedPeersJson: String) {
        Log.i(monitorLogTag, "Starting monitor service on port $port")
        val intent = Intent(this, MonitorService::class.java).apply {
            action = MonitorService.ACTION_START
            putExtra(MonitorService.EXTRA_PORT, port)
            putExtra(MonitorService.EXTRA_IDENTITY_JSON, identityJson)
            putExtra(MonitorService.EXTRA_TRUSTED_PEERS_JSON, trustedPeersJson)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        bindMonitorService()
    }

    private fun stopMonitorService() {
        Log.i(monitorLogTag, "Stopping monitor service")
        val intent = Intent(this, MonitorService::class.java).apply {
            action = MonitorService.ACTION_STOP
        }
        startService(intent)
        unbindMonitorService()
    }

    private fun bindMonitorService() {
        if (!monitorServiceBound) {
            val intent = Intent(this, MonitorService::class.java)
            bindService(intent, monitorServiceConnection, Context.BIND_AUTO_CREATE)
        }
    }

    private fun unbindMonitorService() {
        if (monitorServiceBound) {
            unbindService(monitorServiceConnection)
            monitorServiceBound = false
            monitorService = null
        }
    }

    private fun startListenerService(monitorName: String) {
        Log.i(listenerLogTag, "Starting listener service for: $monitorName")
        val intent = Intent(this, ListenerService::class.java).apply {
            action = ListenerService.ACTION_START
            putExtra("monitorName", monitorName)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopListenerService() {
        Log.i(listenerLogTag, "Stopping listener service")
        val intent = Intent(this, ListenerService::class.java).apply {
            action = ListenerService.ACTION_STOP
        }
        startService(intent)
    }

    private fun stopMdns() {
        mdnsDiscoveryManager?.stopDiscovery()
        pendingMdnsParams = null
        pendingAdvertiseStart = false
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_STOP
        }
        startService(intent)
    }

    // -----------------------------------------------------------------------------
    // Helper methods
    // -----------------------------------------------------------------------------

    private fun buildMdnsIntent(action: String): Intent {
        return Intent(this, AudioCaptureService::class.java).apply {
            this.action = action
            pendingMdnsParams?.let { params ->
                putExtra(AudioCaptureService.EXTRA_REMOTE_DEVICE_ID, params["remoteDeviceId"]?.toString())
                putExtra(AudioCaptureService.EXTRA_MONITOR_NAME, params["monitorName"]?.toString() ?: "Monitor")
                putExtra(AudioCaptureService.EXTRA_MONITOR_CERT_FINGERPRINT, params["certFingerprint"]?.toString() ?: "")
                putExtra(AudioCaptureService.EXTRA_CONTROL_PORT, (params["controlPort"] as? Int) ?: 48080)
                putExtra(AudioCaptureService.EXTRA_PAIRING_PORT, (params["pairingPort"] as? Int) ?: 48081)
                putExtra(AudioCaptureService.EXTRA_VERSION, (params["version"] as? Int) ?: 1)
            }
        }
    }

    private fun resolveDeviceName(): String {
        val resolver = applicationContext.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            val globalName = Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME)
            if (!globalName.isNullOrBlank()) {
                return globalName.trim()
            }
        }

        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        if (manufacturer.isNotEmpty() && model.isNotEmpty()) {
            val combined = if (model.startsWith(manufacturer, ignoreCase = true)) {
                model
            } else {
                manufacturer.replaceFirstChar { it.uppercase() } + " " + model
            }
            if (combined.isNotBlank()) return combined.trim()
        } else if (model.isNotEmpty()) {
            return model
        } else if (manufacturer.isNotEmpty()) {
            return manufacturer.replaceFirstChar { it.uppercase() }
        }

        return Build.DEVICE?.trim()?.takeIf { it.isNotEmpty() } ?: "Android device"
    }

    // -----------------------------------------------------------------------------
    // Permission handling
    // -----------------------------------------------------------------------------

    private fun checkAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestAudioPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            RECORD_AUDIO_PERMISSION_CODE
        )
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    POST_NOTIFICATIONS_PERMISSION_CODE
                )
            }
        }
    }

    // -----------------------------------------------------------------------------
    // Activity lifecycle
    // -----------------------------------------------------------------------------

    override fun onResume() {
        super.onResume()
        if (pendingAdvertiseStart) {
            pendingAdvertiseStart = false
            // Let Flutter handle restart based on monitoring state
        }
    }

    override fun onDestroy() {
        audioPlaybackService?.stop()
        audioPlaybackService = null

        if (audioServiceBound) {
            unbindService(audioServiceConnection)
            audioServiceBound = false
        }

        if (monitorServiceBound) {
            unbindService(monitorServiceConnection)
            monitorServiceBound = false
        }

        mdnsDiscoveryManager?.stopDiscovery()
        super.onDestroy()
    }
}
