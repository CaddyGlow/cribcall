package com.cribcall.cribcall

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Manages mDNS service discovery for finding baby monitors on the network.
 *
 * Handles NSD (Network Service Discovery) operations including:
 * - Starting/stopping discovery
 * - Resolving discovered services
 * - Caching service name to device ID mappings
 * - Emitting online/offline events
 */
class MdnsDiscoveryManager(
    context: Context,
    private val onServiceEvent: (Map<String, Any>) -> Unit
) {
    private val logTag = "cribcall_mdns"
    private val serviceType = "_baby-monitor._tcp."

    private val nsdManager: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // Cache serviceName -> remoteDeviceId mapping for offline events
    private val serviceNameToRemoteDeviceId = mutableMapOf<String, String>()

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Start mDNS service discovery.
     * Events are emitted via [onServiceEvent] callback.
     */
    fun startDiscovery() {
        if (discoveryListener != null) {
            Log.d(logTag, "Discovery already running")
            return
        }

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
                resolveService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                handleServiceLost(serviceInfo)
            }
        }

        discoveryListener = listener
        nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    /**
     * Stop mDNS service discovery.
     */
    fun stopDiscovery() {
        Log.i(logTag, "Stopping NSD discovery")
        discoveryListener?.let { listener ->
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (e: Exception) {
                Log.w(logTag, "Failed to stop discovery: ${e.message}")
            }
        }
        discoveryListener = null
    }

    /**
     * Clear cached service mappings.
     */
    fun clearCache() {
        serviceNameToRemoteDeviceId.clear()
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
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
                handleServiceResolved(resolved)
            }
        })
    }

    private fun handleServiceResolved(resolved: NsdServiceInfo) {
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
            "ip" to (resolved.host?.hostAddress ?: ""),
            "isOnline" to true,
        )

        Log.i(
            logTag,
            "Service resolved $remoteDeviceId ip=${payload["ip"]} " +
            "controlPort=$controlPort pairingPort=$pairingPort transport=$transport",
        )

        mainHandler.post {
            onServiceEvent(payload)
        }
    }

    private fun handleServiceLost(serviceInfo: NsdServiceInfo?) {
        if (serviceInfo == null) {
            Log.w(logTag, "onServiceLost called with null serviceInfo")
            return
        }

        // Look up cached remoteDeviceId, fall back to serviceName
        val remoteDeviceId = serviceNameToRemoteDeviceId[serviceInfo.serviceName]
            ?: serviceInfo.serviceName
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

        mainHandler.post {
            Log.i(logTag, "Emitting OFFLINE event for $remoteDeviceId")
            onServiceEvent(payload)
        }
    }
}
