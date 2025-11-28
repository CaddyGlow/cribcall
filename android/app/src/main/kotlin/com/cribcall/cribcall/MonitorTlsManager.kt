package com.cribcall.cribcall

import android.util.Log
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.openssl.PEMKeyPair
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter
import java.io.ByteArrayInputStream
import java.security.KeyFactory
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Security
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLServerSocketFactory
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Manages TLS configuration for the monitor control server.
 * Handles P-256 ECDSA certificates and mTLS client validation.
 */
class MonitorTlsManager(
    private val serverCertDer: ByteArray,
    private val serverPrivateKey: ByteArray,
    trustedPeerCerts: List<ByteArray>
) {
    private val logTag = "cribcall_tls"

    // Server identity
    private val serverCert: X509Certificate
    private val privateKey: PrivateKey

    // Trust store (fingerprint -> cert)
    private val trustedCerts = ConcurrentHashMap<String, X509Certificate>()

    // SSL context - rebuilt when trust store changes
    @Volatile
    private var sslContext: SSLContext

    init {
        // Register BouncyCastle provider if not already
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.insertProviderAt(BouncyCastleProvider(), 1)
        }

        // Parse server certificate
        serverCert = parseCertificate(serverCertDer)
        val serverFingerprint = fingerprintHex(serverCertDer)
        Log.i(logTag, "Server cert loaded: ${serverFingerprint.take(12)}")

        // Parse server private key (PKCS#8 format)
        privateKey = parsePrivateKey(serverPrivateKey)
        Log.i(logTag, "Server private key loaded: ${privateKey.algorithm}")

        // Add server cert to trust store (for same-device testing)
        trustedCerts[serverFingerprint] = serverCert

        // Add initial trusted peer certs
        for (certDer in trustedPeerCerts) {
            try {
                val cert = parseCertificate(certDer)
                val fp = fingerprintHex(certDer)
                trustedCerts[fp] = cert
                Log.i(logTag, "Added trusted peer: ${fp.take(12)}")
            } catch (e: Exception) {
                Log.w(logTag, "Failed to parse trusted cert: ${e.message}")
            }
        }

        // Build initial SSL context
        sslContext = buildSslContext()
        Log.i(logTag, "SSL context initialized, trustedPeers=${trustedCerts.size}")
    }

    /**
     * Create an SSL server socket bound to the given port.
     */
    fun createServerSocket(port: Int): SSLServerSocket {
        val factory = sslContext.serverSocketFactory
        val serverSocket = factory.createServerSocket(port) as SSLServerSocket

        // Configure for mTLS: require client certificate
        serverSocket.needClientAuth = true

        // Enable only TLS 1.2+ and modern cipher suites
        serverSocket.enabledProtocols = arrayOf("TLSv1.2", "TLSv1.3")
        serverSocket.enabledCipherSuites = serverSocket.supportedCipherSuites.filter { suite ->
            suite.contains("ECDHE") && (suite.contains("AES_128") || suite.contains("AES_256"))
        }.toTypedArray()

        Log.i(logTag, "Server socket created on port $port")
        return serverSocket
    }

    /**
     * Validate a client certificate and return its fingerprint if trusted.
     * Returns null if not trusted.
     */
    fun validateClientCert(socket: SSLSocket): String? {
        try {
            val session = socket.session
            val peerCerts = session.peerCertificates
            if (peerCerts.isEmpty()) {
                Log.w(logTag, "No client certificate provided")
                return null
            }

            val clientCert = peerCerts[0] as? X509Certificate
            if (clientCert == null) {
                Log.w(logTag, "Client certificate is not X509")
                return null
            }

            val fingerprint = fingerprintHex(clientCert.encoded)

            // Check if fingerprint is in our trust store
            if (!trustedCerts.containsKey(fingerprint)) {
                Log.w(logTag, "Client cert not trusted: ${fingerprint.take(12)}")
                return null
            }

            Log.d(logTag, "Client cert validated: ${fingerprint.take(12)}")
            return fingerprint
        } catch (e: Exception) {
            Log.w(logTag, "Client cert validation failed: ${e.message}")
            return null
        }
    }

    /**
     * Check if a fingerprint is trusted.
     */
    fun isTrusted(fingerprint: String): Boolean = trustedCerts.containsKey(fingerprint)

    /**
     * Add a trusted certificate dynamically.
     */
    fun addTrustedCert(certDer: ByteArray) {
        val cert = parseCertificate(certDer)
        val fp = fingerprintHex(certDer)
        trustedCerts[fp] = cert
        rebuildSslContext()
        Log.i(logTag, "Added trusted cert: ${fp.take(12)}, total=${trustedCerts.size}")
    }

    /**
     * Remove a trusted certificate by fingerprint.
     */
    fun removeTrustedCert(fingerprint: String) {
        if (trustedCerts.remove(fingerprint) != null) {
            rebuildSslContext()
            Log.i(logTag, "Removed trusted cert: ${fingerprint.take(12)}, total=${trustedCerts.size}")
        }
    }

    /**
     * Get all trusted fingerprints.
     */
    fun getTrustedFingerprints(): Set<String> = trustedCerts.keys.toSet()

    // -------------------------------------------------------------------------
    // SSL Context Building
    // -------------------------------------------------------------------------

    private fun rebuildSslContext() {
        sslContext = buildSslContext()
        Log.i(logTag, "SSL context rebuilt with ${trustedCerts.size} trusted certs")
    }

    private fun buildSslContext(): SSLContext {
        // Key store for server identity
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry("server", privateKey, charArrayOf(), arrayOf(serverCert))
        }

        // Trust store with all trusted peer certs
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            trustedCerts.forEach { (fp, cert) ->
                setCertificateEntry("peer-${fp.take(12)}", cert)
            }
        }

        // Key manager (server identity)
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore, charArrayOf())

        // Trust manager (peer validation)
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trustStore)

        // Build SSL context
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(kmf.keyManagers, tmf.trustManagers, null)
        return ctx
    }

    // -------------------------------------------------------------------------
    // Parsing Helpers
    // -------------------------------------------------------------------------

    private fun parseCertificate(der: ByteArray): X509Certificate {
        val factory = CertificateFactory.getInstance("X.509")
        return factory.generateCertificate(ByteArrayInputStream(der)) as X509Certificate
    }

    private fun parsePrivateKey(pkcs8: ByteArray): PrivateKey {
        val spec = PKCS8EncodedKeySpec(pkcs8)

        // Try platform provider first
        try {
            val keyFactory = KeyFactory.getInstance("EC")
            return keyFactory.generatePrivate(spec)
        } catch (e: Exception) {
            Log.w(logTag, "PKCS#8 parse failed (default provider): ${e.message}")
        }

        // Try BouncyCastle provider explicitly
        try {
            val keyFactory = KeyFactory.getInstance("EC", BouncyCastleProvider.PROVIDER_NAME)
            return keyFactory.generatePrivate(spec)
        } catch (e: Exception) {
            Log.w(logTag, "PKCS#8 parse failed (BC provider): ${e.message}")
        }

        // Fallback to BouncyCastle ASN.1 parsing
        val keyInfo = PrivateKeyInfo.getInstance(pkcs8)
        val converter = JcaPEMKeyConverter()
        return converter.getPrivateKey(keyInfo)
    }

    companion object {
        /**
         * Compute SHA-256 fingerprint of DER-encoded data as hex string.
         */
        fun fingerprintHex(der: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val hash = digest.digest(der)
            return hash.joinToString("") { "%02x".format(it) }
        }
    }
}
