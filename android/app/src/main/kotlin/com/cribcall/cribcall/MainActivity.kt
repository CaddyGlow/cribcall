package com.cribcall.cribcall

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

class MainActivity : FlutterActivity() {
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private var mdnsEventSink: EventChannel.EventSink? = null
    private val serviceType = "_baby-monitor._tcp."
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val logTag = "cribcall_mdns"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager

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
    }

    private fun startAdvertise(args: Map<*, *>) {
        val manager = nsdManager ?: return
        val info = NsdServiceInfo().apply {
            serviceName =
                "${args["monitorName"] as? String ?: "monitor"}-${args["monitorId"] as? String ?: "id"}"
            serviceType = this@MainActivity.serviceType
            port = (args["servicePort"] as? Int) ?: 48080
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
}
