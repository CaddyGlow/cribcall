import Foundation
import Security
import Network
import CryptoKit
import os.log

/// Manages TLS configuration for the monitor control server.
/// Handles P-256 ECDSA certificates and mTLS client validation.
class MonitorTlsManager {
    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "tls")

    // Server identity
    private let serverCertificate: SecCertificate
    private let serverPrivateKey: SecKey
    private let serverIdentity: SecIdentity
    private let serverFingerprint: String

    // Trust store (fingerprint -> certificate)
    private var trustedCerts: [String: SecCertificate] = [:]
    private let trustedCertsLock = NSLock()
    private var fingerprintCache: [ObjectIdentifier: String] = [:]
    private let fingerprintCacheLock = NSLock()

    init(serverCertDer: Data, serverPrivateKey: Data, trustedPeerCerts: [Data]) throws {
        // Parse server certificate
        guard let cert = SecCertificateCreateWithData(nil, serverCertDer as CFData) else {
            throw TlsError.invalidCertificate("Failed to parse server certificate")
        }
        self.serverCertificate = cert
        self.serverFingerprint = MonitorTlsManager.fingerprintHex(serverCertDer)

        os_log(
            "Server cert loaded: %{public}@",
            log: log,
            type: .info,
            String(serverFingerprint.prefix(12))
        )

        // Parse server private key (PKCS#8 format)
        self.serverPrivateKey = try MonitorTlsManager.parsePrivateKey(serverPrivateKey)
        os_log("Server private key loaded", log: log, type: .info)

        // Create identity (cert + key pair)
        self.serverIdentity = try MonitorTlsManager.createIdentity(
            certificate: cert,
            privateKey: self.serverPrivateKey
        )

        // Add server cert to trust store (for same-device testing)
        trustedCerts[serverFingerprint] = cert

        // Add initial trusted peer certs
        for certDer in trustedPeerCerts {
            if let peerCert = SecCertificateCreateWithData(nil, certDer as CFData) {
                let fp = MonitorTlsManager.fingerprintHex(certDer)
                trustedCerts[fp] = peerCert
                os_log(
                    "Added trusted peer: %{public}@",
                    log: log,
                    type: .info,
                    String(fp.prefix(12))
                )
            }
        }

        os_log(
            "TLS manager initialized, trustedPeers=%{public}d",
            log: log,
            type: .info,
            trustedCerts.count
        )
    }

    // MARK: - TLS Configuration

    /// Create NWProtocolTLS.Options configured for mTLS server.
    func createTlsOptions() -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // Set server identity
        sec_protocol_options_set_local_identity(
            secOptions,
            sec_identity_create(serverIdentity)!
        )

        // Require client authentication
        sec_protocol_options_set_peer_authentication_required(secOptions, true)

        // Set minimum TLS version to 1.2
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)

        // Set up client certificate verification
        sec_protocol_options_set_verify_block(
            secOptions,
            { [weak self] (metadata, trust, complete) in
                self?.verifyClientCertificate(metadata: metadata, trust: trust, complete: complete)
                    ?? complete(false)
            },
            DispatchQueue.global(qos: .userInitiated)
        )

        return tlsOptions
    }

    private func verifyClientCertificate(
        metadata: sec_protocol_metadata_t,
        trust: sec_trust_t,
        complete: @escaping (Bool) -> Void
    ) {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        // Get the client certificate
        guard SecTrustGetCertificateCount(secTrust) > 0,
              let clientCert = SecTrustGetCertificateAtIndex(secTrust, 0) else {
            os_log("No client certificate provided", log: log, type: .error)
            complete(false)
            return
        }

        // Calculate fingerprint
        guard let certData = SecCertificateCopyData(clientCert) as Data? else {
            os_log("Failed to get certificate data", log: log, type: .error)
            complete(false)
            return
        }

        let fingerprint = MonitorTlsManager.fingerprintHex(certData)
        cacheFingerprint(fingerprint, metadata: metadata)

        // Check if fingerprint is trusted
        trustedCertsLock.lock()
        let isTrusted = trustedCerts[fingerprint] != nil
        trustedCertsLock.unlock()

        if isTrusted {
            os_log(
                "Client cert validated: %{public}@",
                log: log,
                type: .info,
                String(fingerprint.prefix(12))
            )
            complete(true)
        } else {
            os_log(
                "Client cert not trusted: %{public}@",
                log: log,
                type: .error,
                String(fingerprint.prefix(12))
            )
            complete(false)
        }
    }

    // MARK: - Trust Store Management

    /// Check if a fingerprint is trusted.
    func isTrusted(fingerprint: String) -> Bool {
        trustedCertsLock.lock()
        defer { trustedCertsLock.unlock() }
        return trustedCerts[fingerprint] != nil
    }

    /// Add a trusted certificate dynamically.
    func addTrustedCert(_ certDer: Data) {
        guard let cert = SecCertificateCreateWithData(nil, certDer as CFData) else {
            os_log("Failed to parse certificate for adding", log: log, type: .error)
            return
        }

        let fp = MonitorTlsManager.fingerprintHex(certDer)

        trustedCertsLock.lock()
        trustedCerts[fp] = cert
        let count = trustedCerts.count
        trustedCertsLock.unlock()

        os_log(
            "Added trusted cert: %{public}@, total=%{public}d",
            log: log,
            type: .info,
            String(fp.prefix(12)),
            count
        )
    }

    /// Remove a trusted certificate by fingerprint.
    func removeTrustedCert(fingerprint: String) {
        trustedCertsLock.lock()
        let removed = trustedCerts.removeValue(forKey: fingerprint) != nil
        let count = trustedCerts.count
        trustedCertsLock.unlock()

        if removed {
            os_log(
                "Removed trusted cert: %{public}@, total=%{public}d",
                log: log,
                type: .info,
                String(fingerprint.prefix(12)),
                count
            )
        }
    }

    /// Get all trusted fingerprints.
    func getTrustedFingerprints() -> Set<String> {
        trustedCertsLock.lock()
        defer { trustedCertsLock.unlock() }
        return Set(trustedCerts.keys)
    }

    // MARK: - Certificate Validation

    /// Validate a client certificate and return its fingerprint if trusted.
    func validateClientCert(_ connection: NWConnection) -> String? {
        // Get the security metadata from the connection
        guard connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata != nil else { return nil }

        // For now, we rely on the verify block set in createTlsOptions
        // This method can be used for additional validation if needed
        return nil
    }

    /// Retrieve cached fingerprint for a given TLS metadata object.
    func fingerprint(for metadata: sec_protocol_metadata_t) -> String? {
        let key = ObjectIdentifier(metadata)
        fingerprintCacheLock.lock()
        defer { fingerprintCacheLock.unlock() }
        return fingerprintCache[key]
    }

    private func cacheFingerprint(_ fingerprint: String, metadata: sec_protocol_metadata_t) {
        let key = ObjectIdentifier(metadata)
        fingerprintCacheLock.lock()
        fingerprintCache[key] = fingerprint
        fingerprintCacheLock.unlock()
    }

    // MARK: - Static Helpers

    /// Compute SHA-256 fingerprint of DER-encoded data as hex string.
    static func fingerprintHex(_ der: Data) -> String {
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a PKCS#8 encoded private key.
    private static func parsePrivateKey(_ pkcs8Data: Data) throws -> SecKey {
        // Try to extract the raw EC key from PKCS#8 wrapper
        // PKCS#8 EC key structure:
        // SEQUENCE {
        //   INTEGER version
        //   SEQUENCE { OID, OID } algorithm
        //   OCTET STRING containing SEC1 EC private key
        // }

        // For P-256, the PKCS#8 header is typically 26 bytes
        // The SEC1 private key starts after that

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]

        var error: Unmanaged<CFError>?

        // Try parsing as PKCS#8 first
        if let key = SecKeyCreateWithData(pkcs8Data as CFData, attributes as CFDictionary, &error) {
            return key
        }

        // If that fails, try to extract the raw key from PKCS#8
        // Skip the PKCS#8 header (typically ~26 bytes for P-256)
        // and look for the SEC1 structure

        // Parse ASN.1 to find the octet string containing the EC key
        if let rawKey = extractEC256PrivateKey(from: pkcs8Data) {
            if let key = SecKeyCreateWithData(rawKey as CFData, attributes as CFDictionary, &error) {
                return key
            }
        }

        if let error = error {
            throw TlsError.invalidPrivateKey("Failed to parse private key: \(error.takeRetainedValue())")
        }

        throw TlsError.invalidPrivateKey("Failed to parse private key")
    }

    /// Extract EC P-256 private key from PKCS#8 wrapper.
    private static func extractEC256PrivateKey(from pkcs8Data: Data) -> Data? {
        // PKCS#8 structure for EC key:
        // 30 xx                    SEQUENCE
        //   02 01 00               INTEGER (version = 0)
        //   30 13                  SEQUENCE (algorithm)
        //     06 07 2a8648ce3d0201   OID (ecPublicKey)
        //     06 08 2a8648ce3d030107 OID (prime256v1)
        //   04 xx                  OCTET STRING (SEC1 private key)
        //     30 xx
        //       02 01 01           INTEGER (version = 1)
        //       04 20 [32 bytes]   OCTET STRING (private key d)
        //       [optional public key]

        // Look for the pattern: 04 20 followed by 32 bytes (the actual private key value)
        // This is a simplified parser that works for P-256 keys

        let bytes = [UInt8](pkcs8Data)

        // Find the inner SEC1 structure
        for i in 0..<(bytes.count - 35) {
            // Look for 04 20 (OCTET STRING of length 32)
            if bytes[i] == 0x04 && bytes[i + 1] == 0x20 {
                // Found a 32-byte octet string - likely the private key
                let privateKeyBytes = Array(bytes[(i + 2)..<(i + 34)])

                // Return as SEC1 format that iOS can parse
                // SEC1 format: 04 + private_d (32 bytes) + public_x (32 bytes) + public_y (32 bytes)
                // But for SecKeyCreateWithData, we need just the raw key

                // Try returning just the 32-byte private key value
                // wrapped in minimal structure
                return Data(privateKeyBytes)
            }
        }

        return nil
    }

    /// Create a SecIdentity from a certificate and private key.
    private static func createIdentity(
        certificate: SecCertificate,
        privateKey: SecKey
    ) throws -> SecIdentity {
        // We need to add the certificate and key to the keychain temporarily
        // to create an identity, then remove them

        let tempLabel = "com.cribcall.temp.\(UUID().uuidString)"

        // Add certificate to keychain
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: tempLabel
        ]

        var status = SecItemAdd(certAddQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw TlsError.keychainError("Failed to add certificate: \(status)")
        }

        // Add private key to keychain
        let keyAddQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: tempLabel,
            kSecAttrApplicationTag as String: tempLabel.data(using: .utf8)!
        ]

        status = SecItemAdd(keyAddQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            // Clean up certificate
            SecItemDelete(certAddQuery as CFDictionary)
            throw TlsError.keychainError("Failed to add private key: \(status)")
        }

        // Get the identity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: tempLabel,
            kSecReturnRef as String: true
        ]

        var identityRef: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)

        // Clean up - remove from keychain
        SecItemDelete(certAddQuery as CFDictionary)
        SecItemDelete(keyAddQuery as CFDictionary)

        if status != errSecSuccess {
            throw TlsError.keychainError("Failed to create identity: \(status)")
        }

        guard let identity = identityRef as! SecIdentity? else {
            throw TlsError.keychainError("Identity not found")
        }

        return identity
    }
}

// MARK: - Errors

enum TlsError: Error {
    case invalidCertificate(String)
    case invalidPrivateKey(String)
    case keychainError(String)
}
