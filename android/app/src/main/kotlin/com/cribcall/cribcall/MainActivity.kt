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
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private var mdnsEventSink: EventChannel.EventSink? = null
    private val serviceType = "_baby-monitor._tcp."
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val logTag = "cribcall_mdns"

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

        MethodChannel(messenger, mdnsChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertise" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("invalid_args", "Missing advertisement", null)
                        return@setMethodCallHandler
                    }
                    startAdvertise(args)
                    result.success(null)
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
                startDiscovery()
            }

            override fun onCancel(arguments: Any?) {
                mdnsEventSink = null
                stopDiscovery()
            }
        })

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

    private fun startAdvertise(args: Map<*, *>) {
        val manager = nsdManager ?: return
        val info = NsdServiceInfo().apply {
            serviceName =
                "${args["monitorName"] as? String ?: "monitor"}-${args["monitorId"] as? String ?: "id"}"
            serviceType = this@MainActivity.serviceType
            port = (args["controlPort"] as? Int) ?: (args["servicePort"] as? Int) ?: 48080
            setAttribute("monitorId", args["monitorId"]?.toString() ?: "")
            setAttribute("monitorName", args["monitorName"]?.toString() ?: "")
            setAttribute(
                "monitorCertFingerprint",
                args["monitorCertFingerprint"]?.toString() ?: "",
            )
            setAttribute("version", (args["version"] ?: "1").toString())
        }
        Log.i(
            logTag,
            "Starting NSD advertise name=${info.serviceName} port=${info.port} monitorId=${args["monitorId"]}",
        )
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                registrationListener = this
                Log.i(
                    logTag,
                    "Advertise registered ${serviceInfo?.serviceName ?: "unknown"}",
                )
            }

            override fun onRegistrationFailed(
                serviceInfo: NsdServiceInfo?,
                errorCode: Int,
            ) {
                Log.w(logTag, "Advertise failed $errorCode for ${serviceInfo?.serviceName}")
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {
                Log.i(logTag, "Advertise unregistered ${serviceInfo?.serviceName}")
            }
            override fun onUnregistrationFailed(
                serviceInfo: NsdServiceInfo?,
                errorCode: Int,
            ) {
                Log.w(logTag, "Advertise unregistration failed $errorCode")
            }
        }
        registrationListener = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
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
        Log.i(logTag, "Stopping NSD advertise/discovery")
        stopDiscovery()
        nsdManager?.let { mgr ->
            registrationListener?.let {
                try {
                    mgr.unregisterService(it)
                } catch (e: Exception) {
                    Log.w(logTag, "Failed to unregister service: ${e.message}")
                }
            }
        }
        registrationListener = null
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
