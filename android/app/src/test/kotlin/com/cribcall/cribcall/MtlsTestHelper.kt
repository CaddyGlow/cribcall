package com.cribcall.cribcall

import org.bouncycastle.asn1.ASN1EncodableVector
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1Sequence
import org.bouncycastle.asn1.DERBitString
import org.bouncycastle.asn1.DERSequence
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Certificate
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.ExtendedKeyUsage
import org.bouncycastle.asn1.x509.KeyPurposeId
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.asn1.x509.TBSCertificate
import org.bouncycastle.asn1.x509.Time
import org.bouncycastle.asn1.x509.V3TBSCertificateGenerator
import org.bouncycastle.cert.X509CertificateHolder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.ContentSigner
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Security
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.UUID
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/**
 * Test identity for mTLS testing.
 */
data class TestIdentity(
    val deviceId: String,
    val keyPair: KeyPair,
    val certificate: X509Certificate,
    val certificateDer: ByteArray,
    val fingerprint: String,
    val privateKeyPkcs8: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TestIdentity) return false
        return deviceId == other.deviceId && fingerprint == other.fingerprint
    }

    override fun hashCode(): Int {
        return 31 * deviceId.hashCode() + fingerprint.hashCode()
    }
}

/**
 * Collection of test identities for mTLS testing.
 */
data class MtlsTestIdentities(
    val monitor: TestIdentity,
    val trusted: TestIdentity,
    val untrusted: TestIdentity
)

/**
 * Helper class for creating test certificates and SSL contexts for mTLS testing.
 */
object MtlsTestHelper {

    init {
        // Register BouncyCastle provider
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.insertProviderAt(BouncyCastleProvider(), 1)
        }
    }

    /**
     * Generate all test identities needed for mTLS conformance testing.
     */
    fun generateTestIdentities(): MtlsTestIdentities {
        return MtlsTestIdentities(
            monitor = generateIdentity("monitor-test"),
            trusted = generateIdentity("trusted-listener"),
            untrusted = generateIdentity("untrusted-listener")
        )
    }

    /**
     * Generate a single test identity with P-256 ECDSA key pair and self-signed certificate.
     */
    fun generateIdentity(deviceId: String = UUID.randomUUID().toString()): TestIdentity {
        // Generate P-256 key pair
        val keyPairGen = KeyPairGenerator.getInstance("EC", BouncyCastleProvider.PROVIDER_NAME)
        keyPairGen.initialize(ECGenParameterSpec("secp256r1"), SecureRandom())
        val keyPair = keyPairGen.generateKeyPair()

        // Build self-signed certificate
        val certificate = buildSelfSignedCertificate(deviceId, keyPair)
        val certificateDer = certificate.encoded
        val fingerprint = fingerprintHex(certificateDer)

        // Export private key as PKCS#8
        val privateKeyPkcs8 = keyPair.private.encoded

        return TestIdentity(
            deviceId = deviceId,
            keyPair = keyPair,
            certificate = certificate,
            certificateDer = certificateDer,
            fingerprint = fingerprint,
            privateKeyPkcs8 = privateKeyPkcs8
        )
    }

    /**
     * Build a self-signed X.509 certificate for testing.
     */
    private fun buildSelfSignedCertificate(deviceId: String, keyPair: KeyPair): X509Certificate {
        val now = Date()
        val notBefore = Date(now.time - 3600_000) // 1 hour ago
        val notAfter = Date(now.time + 365L * 24 * 3600_000) // 1 year from now

        val subject = X500Name("CN=cribcall-$deviceId")
        val serial = BigInteger(128, SecureRandom())

        val certBuilder = JcaX509v3CertificateBuilder(
            subject, // issuer (self-signed)
            serial,
            notBefore,
            notAfter,
            subject, // subject
            keyPair.public
        )

        // Add extensions
        certBuilder.addExtension(
            Extension.basicConstraints,
            true, // critical
            BasicConstraints(true) // isCA = true
        )

        certBuilder.addExtension(
            Extension.keyUsage,
            true,
            KeyUsage(KeyUsage.digitalSignature or KeyUsage.keyCertSign)
        )

        certBuilder.addExtension(
            Extension.extendedKeyUsage,
            false,
            ExtendedKeyUsage(arrayOf(
                KeyPurposeId.id_kp_serverAuth,
                KeyPurposeId.id_kp_clientAuth
            ))
        )

        // Sign with ECDSA SHA-256
        val contentSigner = JcaContentSignerBuilder("SHA256withECDSA")
            .setProvider(BouncyCastleProvider.PROVIDER_NAME)
            .build(keyPair.private)

        val certHolder = certBuilder.build(contentSigner)
        return JcaX509CertificateConverter()
            .setProvider(BouncyCastleProvider.PROVIDER_NAME)
            .getCertificate(certHolder)
    }

    /**
     * Compute SHA-256 fingerprint of DER-encoded data as lowercase hex string.
     */
    fun fingerprintHex(der: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(der)
        return hash.joinToString("") { "%02x".format(it) }
    }

    /**
     * Create an SSL context for a server with the given identity and trusted certificates.
     *
     * @param serverIdentity The server's identity (certificate + private key)
     * @param trustedCerts Certificates to add to the trust store (fingerprint validated)
     * @param knownUntrustedCerts Certificates to accept at TLS level but not trust
     */
    fun createServerSslContext(
        serverIdentity: TestIdentity,
        trustedCerts: List<TestIdentity>,
        knownUntrustedCerts: List<TestIdentity> = emptyList()
    ): SSLContext {
        // Key store for server identity
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry(
                "server",
                serverIdentity.keyPair.private,
                charArrayOf(),
                arrayOf(serverIdentity.certificate)
            )
        }

        // Trust store with all certificates (trusted + known untrusted for TLS acceptance)
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            // Add server's own cert
            setCertificateEntry("server", serverIdentity.certificate)
            // Add trusted peers
            trustedCerts.forEach { identity ->
                setCertificateEntry("trusted-${identity.fingerprint.take(12)}", identity.certificate)
            }
            // Add known untrusted (for TLS acceptance, not application trust)
            knownUntrustedCerts.forEach { identity ->
                setCertificateEntry("untrusted-${identity.fingerprint.take(12)}", identity.certificate)
            }
        }

        // Key manager
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore, charArrayOf())

        // Trust manager
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trustStore)

        // Build SSL context
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(kmf.keyManagers, tmf.trustManagers, SecureRandom())
        return ctx
    }

    /**
     * Create an SSL context for a client with the given identity.
     *
     * @param clientIdentity The client's identity (for client certificate auth)
     * @param trustedServerCert The server certificate to trust
     */
    fun createClientSslContext(
        clientIdentity: TestIdentity?,
        trustedServerCert: TestIdentity
    ): SSLContext {
        // Key store for client identity (if provided)
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            if (clientIdentity != null) {
                setKeyEntry(
                    "client",
                    clientIdentity.keyPair.private,
                    charArrayOf(),
                    arrayOf(clientIdentity.certificate)
                )
            }
        }

        // Trust store with server certificate
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("server", trustedServerCert.certificate)
        }

        // Key manager (for client cert)
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore, charArrayOf())

        // Trust manager
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trustStore)

        // Build SSL context
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(kmf.keyManagers, tmf.trustManagers, SecureRandom())
        return ctx
    }
}
