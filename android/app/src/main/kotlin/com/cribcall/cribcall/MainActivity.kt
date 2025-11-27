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

class MainActivity : FlutterActivity() {
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private var mdnsEventSink: EventChannel.EventSink? = null
    private val serviceType = "_baby-monitor._tcp."
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    // Note: mDNS advertising (registrationListener) moved to AudioCaptureService
    private val logTag = "cribcall_mdns"
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

    // Service binding
    private var audioCaptureService: AudioCaptureService? = null
    private var serviceBound = false

    // Pending mDNS params to pass to AudioCaptureService
    private var pendingMdnsParams: Map<*, *>? = null

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
                    // mDNS advertising is now handled by AudioCaptureService
                    // Store params for when audio capture starts
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        pendingMdnsParams = args
                        Log.i(logTag, "Stored mDNS params for AudioCaptureService")
                    }
                    result.success(null)
                }
                "stop" -> {
                    stopMdns()
                    pendingMdnsParams = null
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
                        Log.i(audioLogTag, "Audio start with mDNS params: monitorId=${args["monitorId"]}")
                    }
                    startAudioCaptureService()
                    result.success(null)
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
                else -> result.notImplemented()
            }
        }
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
                        val payload = mapOf(
                            "monitorId" to (txt["monitorId"] ?: resolved.serviceName),
                            "monitorName" to (txt["monitorName"] ?: resolved.serviceName),
                            "monitorCertFingerprint" to (txt["monitorCertFingerprint"] ?: ""),
                            "servicePort" to resolved.port,
                            "version" to versionValue,
                            "ip" to resolved.host?.hostAddress,
                        )
                        Handler(Looper.getMainLooper()).post {
                            mdnsEventSink?.success(payload)
                        }
                        Log.i(
                            logTag,
                            "Service resolved ${payload["monitorId"]} ip=${payload["ip"]} port=${payload["servicePort"]}",
                        )
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {}
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

    // Foreground service methods
    private fun startAudioCaptureService() {
        Log.i(audioLogTag, "Starting audio capture foreground service")
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_START

            // Pass mDNS params if available
            pendingMdnsParams?.let { params ->
                putExtra(AudioCaptureService.EXTRA_MONITOR_ID, params["monitorId"]?.toString())
                putExtra(AudioCaptureService.EXTRA_MONITOR_NAME, params["monitorName"]?.toString() ?: "Monitor")
                putExtra(AudioCaptureService.EXTRA_MONITOR_CERT_FINGERPRINT, params["monitorCertFingerprint"]?.toString() ?: "")
                putExtra(AudioCaptureService.EXTRA_CONTROL_PORT, (params["controlPort"] as? Int) ?: 48080)
                putExtra(AudioCaptureService.EXTRA_PAIRING_PORT, (params["pairingPort"] as? Int) ?: 48081)
                putExtra(AudioCaptureService.EXTRA_VERSION, (params["version"] as? Int) ?: 1)
                Log.i(audioLogTag, "Passing mDNS params to AudioCaptureService: monitorId=${params["monitorId"]}")
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopAudioCaptureService() {
        Log.i(audioLogTag, "Stopping audio capture foreground service")
        val intent = Intent(this, AudioCaptureService::class.java).apply {
            action = AudioCaptureService.ACTION_STOP
        }
        startService(intent)
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
        stopMdns()
        super.onDestroy()
    }
}
