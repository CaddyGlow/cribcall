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
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle

class MainActivity : FlutterActivity() {
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private var mdnsEventSink: EventChannel.EventSink? = null
    private val serviceType = "_baby-monitor._tcp."
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    // Note: mDNS advertising (registrationListener) moved to AudioCaptureService
    private val logTag = "cribcall_mdns"
    // Cache serviceName -> remoteDeviceId mapping for offline events
    private val serviceNameToRemoteDeviceId = mutableMapOf<String, String>()
    private val deviceInfoChannel = "cribcall/device_info"

    // Audio capture via foreground service
    private val audioChannel = "cribcall/audio"
    private val audioEvents = "cribcall/audio_events"
    private var audioEventSink: EventChannel.EventSink? = null
    private val audioLogTag = "cribcall_audio"
    private val RECORD_AUDIO_PERMISSION_CODE = 1001
    private val POST_NOTIFICATIONS_PERMISSION_CODE = 1002

    // Listener foreground service
    private val listenerChannel = "cribcall/listener"
    private val listenerLogTag = "cribcall_listener"

    // Audio playback for listener side
    private val audioPlaybackChannel = "cribcall/audio_playback"
    private val audioPlaybackLogTag = "cribcall_audio_playback"
    private var audioPlaybackService: AudioPlaybackService? = null

    // Monitor server (control server foreground service)
    private val monitorServerChannel = "cribcall/monitor_server"
    private val monitorEventsChannel = "cribcall/monitor_events"
    private val monitorLogTag = "cribcall_monitor"
    private var monitorEventSink: EventChannel.EventSink? = null
    private var monitorService: MonitorService? = null
    private var monitorServiceBound = false

    // Service binding
    private var audioCaptureService: AudioCaptureService? = null
    private var serviceBound = false

    // Pending mDNS params to pass to AudioCaptureService
    private var pendingMdnsParams: Map<*, *>? = null

    // Track pending advertise-only service starts when backgrounded
    private var pendingAdvertiseStart = false

    private enum class AdvertiseStartResult {
        STARTED,
        DEFERRED,
        FAILED
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as AudioCaptureService.LocalBinder
            audioCaptureService = binder.getService()
            serviceBound = true
            Log.i(audioLogTag, "AudioCaptureService bound")

            // Set up callback to forward audio data to Flutter
            audioCaptureService?.onAudioData = { bytes ->
                if (audioEventSink != null) {
                    audioEventSink?.success(bytes)
                } else {
                    Log.w(audioLogTag, "onAudioData: audioEventSink is null, dropping ${bytes.size} bytes")
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            audioCaptureService = null
            serviceBound = false
            Log.i(audioLogTag, "AudioCaptureService unbound")
        }
    }

    private val monitorServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as MonitorService.LocalBinder
            monitorService = binder.getService()
            monitorServiceBound = true
            Log.i(monitorLogTag, "MonitorService bound")

            // Set up callbacks to forward events to Flutter
            setupMonitorServiceCallbacks()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            monitorService = null
            monitorServiceBound = false
            Log.i(monitorLogTag, "MonitorService unbound")
        }
    }

    private fun setupMonitorServiceCallbacks() {
        val handler = Handler(Looper.getMainLooper())

        monitorService?.onServerStarted = { port ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "serverStarted",
                    "port" to port
                ))
            }
        }

        monitorService?.onServerError = { error ->
            handler.post {
                monitorEventSink?.success(mapOf(
                    "event" to "serverError",
                    "error" to error
                ))
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager

        // Bind to audio service early
        bindAudioService()

        // mDNS channel - advertising is now handled by AudioCaptureService
        // This channel only handles discovery for listeners
        MethodChannel(messenger, mdnsChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertise" -> {
                    // mDNS advertising is handled by AudioCaptureService
                    // Store params and start advertise-only foreground service
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        pendingMdnsParams = args
                        Log.i(logTag, "Stored mDNS params for AudioCaptureService")
                        when (startAdvertiseService()) {
                            AdvertiseStartResult.STARTED -> result.success(null)
                            AdvertiseStartResult.DEFERRED -> result.error(
                                "foreground_service_not_allowed",
                                "Cannot start advertise foreground service while app is in background. " +
                                    "Open CribCall to resume advertising.",
                                null
                            )
                            AdvertiseStartResult.FAILED -> result.error(
                                "service_start_failed",
                                "Failed to start advertise foreground service.",
                                null
                            )
                        }
                    } else {
                        result.success(null)
                    }
                }
                "stop" -> {
                    stopMdns()
                    pendingMdnsParams = null
                    pendingAdvertiseStart = false
                    stopAdvertiseService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, mdnsEvents).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                mdnsEventSink = events
                startDiscovery()
            }

            override fun onCancel(arguments: Any?) {
                mdnsEventSink = null
                stopDiscovery()
            }
        })

        MethodChannel(messenger, deviceInfoChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceName" -> {
                    result.success(resolveDeviceName())
                }
                else -> result.notImplemented()
            }
        }

        // Audio capture channels (now using foreground service)
        MethodChannel(messenger, audioChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (!checkAudioPermission()) {
                        requestAudioPermission()
                        result.error("permission_denied", "RECORD_AUDIO permission required", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !checkNotificationPermission()) {
                        requestNotificationPermission()
                        // Continue anyway - notification permission is not strictly required
                    }
                    // Get mDNS params if provided directly in the start call
                    val args = call.arguments as? Map<*, *>
                    if (args != null && args.isNotEmpty()) {
                        pendingMdnsParams = args
                        Log.i(audioLogTag, "Audio start with mDNS params: remoteDeviceId=${args["remoteDeviceId"]}")
                    }
                    try {
                        startAudioCaptureService()
                        result.success(null)
                    } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
                        Log.e(audioLogTag, "Cannot start foreground service from background: ${e.message}")
                        result.error(
                            "foreground_service_not_allowed",
                            "Cannot start audio capture while app is in background. Please open the app first.",
                            e.message
                        )
                    } catch (e: Exception) {
                        Log.e(audioLogTag, "Failed to start audio capture service: ${e.message}")
                        result.error("service_start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    stopAudioCaptureService()
                    result.success(null)
                }
                "hasPermission" -> {
                    result.success(checkAudioPermission())
                }
                "requestPermission" -> {
                    if (checkAudioPermission()) {
                        result.success(true)
                    } else {
                        requestAudioPermission()
                        result.success(false)
                    }
                }
                "isRunning" -> {
                    result.success(audioCaptureService?.isCapturing() == true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, audioEvents).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioEventSink = events
                Log.i(audioLogTag, "Audio event channel connected, sink=${events != null}, serviceBound=$serviceBound")
                // Update callback if service is already bound
                audioCaptureService?.onAudioData = { bytes ->
                    if (audioEventSink != null) {
                        audioEventSink?.success(bytes)
                    } else {
                        Log.w(audioLogTag, "onAudioData (onListen): audioEventSink is null")
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                audioEventSink = null
                Log.i(audioLogTag, "Audio event channel disconnected")
            }
        })

        // Listener foreground service channel
        MethodChannel(messenger, listenerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val monitorName = call.argument<String>("monitorName") ?: "Monitor"
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !checkNotificationPermission()) {
                        requestNotificationPermission()
                    }
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

        // Audio playback channel (for listener receiving audio via data channel)
        MethodChannel(messenger, audioPlaybackChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (audioPlaybackService == null) {
                        audioPlaybackService = AudioPlaybackService()
                    }
                    val success = audioPlaybackService?.start() == true
                    Log.i(audioPlaybackLogTag, "Audio playback start: $success")
                    result.success(success)
                }
                "stop" -> {
                    audioPlaybackService?.stop()
                    audioPlaybackService = null
                    Log.i(audioPlaybackLogTag, "Audio playback stopped")
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

        // Monitor server channel (control server for baby monitor)
        MethodChannel(messenger, monitorServerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val port = call.argument<Int>("port") ?: 48080
                    val identityJson = call.argument<String>("identityJson")
                    val trustedPeersJson = call.argument<String>("trustedPeersJson") ?: "[]"

                    if (identityJson == null) {
                        result.error("invalid_args", "Missing identityJson", null)
                        return@setMethodCallHandler
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !checkNotificationPermission()) {
                        requestNotificationPermission()
                    }

                    try {
                        startMonitorService(port, identityJson, trustedPeersJson)
                        result.success(null)
                    } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
                        Log.e(monitorLogTag, "Cannot start monitor service from background: ${e.message}")
                        result.error(
                            "foreground_service_not_allowed",
                            "Cannot start monitor server while app is in background.",
                            e.message
                        )
                    } catch (e: Exception) {
                        Log.e(monitorLogTag, "Failed to start monitor service: ${e.message}")
                        result.error("service_start_failed", e.message, null)
                    }
                }
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
                "isRunning" -> {
                    result.success(monitorService?.isRunning() == true)
                }
                "getPort" -> {
                    result.success(monitorService?.getPort())
                }
                else -> result.notImplemented()
            }
        }

        // Monitor events channel
        EventChannel(messenger, monitorEventsChannel).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                monitorEventSink = events
                Log.i(monitorLogTag, "Monitor event channel connected")
                // If service is already bound, reconnect callbacks
                if (monitorServiceBound) {
                    setupMonitorServiceCallbacks()
                }
            }

            override fun onCancel(arguments: Any?) {
                monitorEventSink = null
                Log.i(monitorLogTag, "Monitor event channel disconnected")
            }
        })
    }

    private fun bindAudioService() {
        val intent = Intent(this, AudioCaptureService::class.java)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
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
            if (combined.isNotBlank()) {
                return combined.trim()
            }
        } else if (model.isNotEmpty()) {
            return model
        } else if (manufacturer.isNotEmpty()) {
            return manufacturer.replaceFirstChar { it.uppercase() }
        }

        val device = Build.DEVICE?.trim().orEmpty()
        if (device.isNotEmpty()) {
            return device
        }

        return "Android device"
    }

    private fun startDiscovery() {
        val manager = nsdManager ?: return
        if (discoveryListener != null) return
        Log.i(logTag, "Starting NSD discovery")
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.w(logTag, "Discovery start failed $errorCode for $serviceType")
            }
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.w(logTag, "Discovery stop failed $errorCode for $serviceType")
            }
            override fun onDiscoveryStarted(regType: String?) {
                Log.i(logTag, "Discovery started for $regType")
            }
            override fun onDiscoveryStopped(serviceType: String?) {
                Log.i(logTag, "Discovery stopped for $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.i(
                    logTag,
                    "Service found ${serviceInfo.serviceName} ${serviceInfo.host?.hostAddress}",
                )
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        serviceInfo: NsdServiceInfo?,
                        errorCode: Int,
                    ) {
                        Log.w(
                            logTag,
                            "Resolve failed $errorCode for ${serviceInfo?.serviceName}",
                        )
                    }

                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val txt = resolved.attributes.mapValues { entry ->
                            String(entry.value)
                        }
                        val versionValue = txt["version"]?.toIntOrNull() ?: 1
                        val controlPort = txt["controlPort"]?.toIntOrNull() ?: resolved.port
                        val pairingPort = txt["pairingPort"]?.toIntOrNull() ?: 48081
                        val transport = txt["transport"] ?: "http-ws"
                        val remoteDeviceId = txt["remoteDeviceId"] ?: resolved.serviceName
                        val monitorName = txt["monitorName"] ?: resolved.serviceName

                        // Cache serviceName -> remoteDeviceId for offline events
                        serviceNameToRemoteDeviceId[resolved.serviceName] = remoteDeviceId

                        val payload = mapOf(
                            "remoteDeviceId" to remoteDeviceId,
                            "monitorName" to monitorName,
                            "certFingerprint" to (txt["monitorCertFingerprint"] ?: ""),
                            "controlPort" to controlPort,
                            "pairingPort" to pairingPort,
                            "version" to versionValue,
                            "transport" to transport,
                            "ip" to resolved.host?.hostAddress,
                            "isOnline" to true,
                        )
                        Handler(Looper.getMainLooper()).post {
                            val hasSink = mdnsEventSink != null
                            Log.i(
                                logTag,
                                "Emitting ONLINE event for $remoteDeviceId, hasSink=$hasSink",
                            )
                            mdnsEventSink?.success(payload)
                        }
                        Log.i(
                            logTag,
                            "Service resolved $remoteDeviceId ip=${payload["ip"]} " +
                            "controlPort=$controlPort pairingPort=$pairingPort transport=$transport",
                        )
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                if (serviceInfo == null) {
                    Log.w(logTag, "onServiceLost called with null serviceInfo")
                    return
                }
                // Look up cached remoteDeviceId, fall back to serviceName
                val remoteDeviceId = serviceNameToRemoteDeviceId[serviceInfo.serviceName] ?: serviceInfo.serviceName
                val wasCached = serviceNameToRemoteDeviceId.containsKey(serviceInfo.serviceName)
                Log.i(
                    logTag,
                    "Service lost: serviceName=${serviceInfo.serviceName} " +
                    "remoteDeviceId=$remoteDeviceId wasCached=$wasCached"
                )

                // Remove from cache
                serviceNameToRemoteDeviceId.remove(serviceInfo.serviceName)

                // Emit offline event
                val payload = mapOf(
                    "remoteDeviceId" to remoteDeviceId,
                    "monitorName" to serviceInfo.serviceName,
                    "certFingerprint" to "",
                    "controlPort" to 48080,
                    "pairingPort" to 48081,
                    "version" to 1,
                    "transport" to "http-ws",
                    "ip" to (serviceInfo.host?.hostAddress ?: ""),
                    "isOnline" to false,
                )
                Handler(Looper.getMainLooper()).post {
                    val hasSink = mdnsEventSink != null
                    Log.i(
                        logTag,
                        "Emitting OFFLINE event for $remoteDeviceId, hasSink=$hasSink"
                    )
                    mdnsEventSink?.success(payload)
                }
            }
        }
        discoveryListener = listener
        manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopDiscovery() {
        val manager = nsdManager ?: return
        Log.i(logTag, "Stopping NSD discovery")
        discoveryListener?.let {
            try {
                manager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.w(logTag, "Failed to stop discovery: ${e.message}")
            }
        }
        discoveryListener = null
    }

    private fun stopMdns() {
        Log.i(logTag, "Stopping NSD discovery")
        stopDiscovery()
        // Note: mDNS advertising is stopped by AudioCaptureService
    }

    override fun onResume() {
        super.onResume()
        resumeAdvertiseIfPending()
    }

    // Audio permission methods
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

    private fun checkNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                POST_NOTIFICATIONS_PERMISSION_CODE
            )
        }
    }

    private fun buildMdnsIntent(action: String): Intent {
        return Intent(this, AudioCaptureService::class.java).apply {
            this.action = action

            // Pass mDNS params if available
            pendingMdnsParams?.let { params ->
                putExtra(AudioCaptureService.EXTRA_REMOTE_DEVICE_ID, params["remoteDeviceId"]?.toString())
                putExtra(AudioCaptureService.EXTRA_MONITOR_NAME, params["monitorName"]?.toString() ?: "Monitor")
                // Dart sends 'certFingerprint', map to internal EXTRA_MONITOR_CERT_FINGERPRINT
                putExtra(AudioCaptureService.EXTRA_MONITOR_CERT_FINGERPRINT, params["certFingerprint"]?.toString() ?: "")
                putExtra(AudioCaptureService.EXTRA_CONTROL_PORT, (params["controlPort"] as? Int) ?: 48080)
                putExtra(AudioCaptureService.EXTRA_PAIRING_PORT, (params["pairingPort"] as? Int) ?: 48081)
                putExtra(AudioCaptureService.EXTRA_VERSION, (params["version"] as? Int) ?: 1)
                Log.i(audioLogTag, "Passing mDNS params to AudioCaptureService: remoteDeviceId=${params["remoteDeviceId"]} certFingerprint=${params["certFingerprint"]?.toString()?.take(16)}...")
            }
        }
    }

    // Foreground service methods
    private fun startAudioCaptureService() {
        Log.i(audioLogTag, "Starting audio capture foreground service")
        val intent = buildMdnsIntent(AudioCaptureService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun startAdvertiseService(): AdvertiseStartResult {
        Log.i(audioLogTag, "Starting advertise-only foreground service")
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        ) {
            Log.w(audioLogTag, "Deferring advertise-only start: activity not in foreground")
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
            Log.e(
                audioLogTag,
                "Cannot start advertise-only foreground service while backgrounded: ${e.message}"
            )
            AdvertiseStartResult.DEFERRED
        } catch (e: Exception) {
            pendingAdvertiseStart = false
            Log.e(audioLogTag, "Failed to start advertise-only service: ${e.message}")
            AdvertiseStartResult.FAILED
        }
    }

    private fun stopAudioCaptureService() {
        Log.i(audioLogTag, "Stopping audio capture foreground service")
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_STOP
        }
        startService(intent)
    }

    // Monitor service methods
    private fun startMonitorService(port: Int, identityJson: String, trustedPeersJson: String) {
        Log.i(monitorLogTag, "Starting monitor foreground service on port $port")
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
        // Bind to get callbacks
        bindMonitorService()
    }

    private fun stopMonitorService() {
        Log.i(monitorLogTag, "Stopping monitor foreground service")
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

    private fun stopAdvertiseService() {
        Log.i(audioLogTag, "Stopping advertise-only foreground service")
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_STOP
        }
        startService(intent)
    }

    private fun resumeAdvertiseIfPending() {
        if (!pendingAdvertiseStart) return
        // Do not auto-start from resume; leave it to the Flutter app to decide
        // based on current monitoring state.
        Log.i(
            audioLogTag,
            "Pending advertise-only start will be handled by Flutter; skipping auto-resume"
        )
        pendingAdvertiseStart = false
    }

    // Listener foreground service methods
    private fun startListenerService(monitorName: String) {
        Log.i(listenerLogTag, "Starting listener foreground service for: $monitorName")
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
        Log.i(listenerLogTag, "Stopping listener foreground service")
        val intent = Intent(this, ListenerService::class.java).apply {
            action = ListenerService.ACTION_STOP
        }
        startService(intent)
    }

    override fun onDestroy() {
        // Clean up audio playback
        audioPlaybackService?.stop()
        audioPlaybackService = null

        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
        }

        // Clean up monitor service binding (but don't stop the service - it should survive)
        if (monitorServiceBound) {
            unbindService(monitorServiceConnection)
            monitorServiceBound = false
        }

        stopMdns()
        super.onDestroy()
    }
}
