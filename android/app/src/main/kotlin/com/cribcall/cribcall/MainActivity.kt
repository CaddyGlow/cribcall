package com.cribcall.cribcall

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.content.Context

class MainActivity : FlutterActivity() {
    private val mdnsChannel = "cribcall/mdns"
    private val mdnsEvents = "cribcall/mdns_events"
    private var mdnsEventSink: EventChannel.EventSink? = null
    private val serviceType = "_baby-monitor._tcp."
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

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
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                registrationListener = this
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
        }
        registrationListener = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun startDiscovery() {
        val manager = nsdManager ?: return
        if (discoveryListener != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
            override fun onDiscoveryStarted(regType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}

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
                        mdnsEventSink?.success(payload)
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
        discoveryListener?.let {
            try {
                manager.stopServiceDiscovery(it)
            } catch (e: Exception) {
            }
        }
        discoveryListener = null
    }

    private fun stopMdns() {
        stopDiscovery()
        nsdManager?.let { mgr ->
            registrationListener?.let {
                try {
                    mgr.unregisterService(it)
                } catch (e: Exception) {
                }
            }
        }
        registrationListener = null
    }
}
