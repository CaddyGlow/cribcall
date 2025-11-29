import Foundation
import os.log

/// Coordinates the monitor control server components.
/// Provides the interface matching Android's MonitorService for platform channels.
class MonitorService {
    static let shared = MonitorService()

    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "monitor_svc")

    private var tlsManager: MonitorTlsManager?
    private var webSocketServer: ControlWebSocketServer?
    private var serverPort: Int?

    // Event callbacks (set from AppDelegate)
    var onServerStarted: ((Int) -> Void)?
    var onServerError: ((String) -> Void)?
    var onClientConnected: ((String, String, String) -> Void)?  // connectionId, fingerprint, remoteAddress
    var onClientDisconnected: ((String, String?) -> Void)?      // connectionId, reason
    var onWsMessage: ((String, String) -> Void)?                // connectionId, messageJson
    var onHttpRequest: ((String, String, String, String?, String?) -> Void)?  // requestId, method, path, fingerprint, bodyJson

    // Pending HTTP requests awaiting Dart response
    private var pendingHttpRequests: [String: (Int, String?) -> Void] = [:]
    private let pendingLock = NSLock()
    private var requestIdCounter = 0

    private init() {}

    // MARK: - Server Lifecycle

    func start(port: Int, identityJson: String, trustedPeersJson: String) {
        os_log("Starting monitor service on port %{public}d", log: log, type: .info, port)

        do {
            // Parse identity
            let identity = try parseIdentity(identityJson)

            // Parse trusted peers
            let trustedPeers = try parseTrustedPeers(trustedPeersJson)

            // Initialize TLS manager
            tlsManager = try MonitorTlsManager(
                serverCertDer: identity.certDer,
                serverPrivateKey: identity.privateKey,
                trustedPeerCerts: trustedPeers.compactMap { $0.certDer }
            )

            // Initialize WebSocket server
            webSocketServer = ControlWebSocketServer(
                port: UInt16(port),
                tlsManager: tlsManager!
            )

            // Set up callbacks
            webSocketServer?.onClientConnected = { [weak self] connId, fingerprint, addr in
                os_log("Client connected: %{public}@ fp=%{public}@", log: self?.log ?? .default, type: .info, connId, String(fingerprint.prefix(12)))
                self?.onClientConnected?(connId, fingerprint, addr)
            }

            webSocketServer?.onClientDisconnected = { [weak self] connId, reason in
                os_log("Client disconnected: %{public}@ reason=%{public}@", log: self?.log ?? .default, type: .info, connId, reason ?? "none")
                self?.onClientDisconnected?(connId, reason)
            }

            webSocketServer?.onWsMessage = { [weak self] connId, message in
                os_log("WS message from %{public}@: %{public}@", log: self?.log ?? .default, type: .debug, connId, String(message.prefix(100)))
                self?.onWsMessage?(connId, message)
            }

            webSocketServer?.onHttpRequest = { [weak self] requestId, method, path, fingerprint, body, responder in
                guard let self = self else { return }

                os_log("HTTP request %{public}@: %{public}@ %{public}@ fp=%{public}@", log: self.log, type: .info, requestId, method, path, fingerprint?.prefix(12).description ?? "none")

                self.pendingLock.lock()
                self.pendingHttpRequests[requestId] = responder
                self.pendingLock.unlock()

                self.onHttpRequest?(requestId, method, path, fingerprint, body)
            }

            // Start server
            try webSocketServer?.start()
            serverPort = port

            os_log("Monitor service started on port %{public}d", log: log, type: .info, port)
            onServerStarted?(port)

        } catch {
            os_log("Monitor service start failed: %{public}@", log: log, type: .error, error.localizedDescription)
            onServerError?(error.localizedDescription)
            stop()
        }
    }

    func stop() {
        os_log("Stopping monitor service", log: log, type: .info)

        webSocketServer?.stop()
        webSocketServer = nil
        tlsManager = nil
        serverPort = nil

        pendingLock.lock()
        pendingHttpRequests.removeAll()
        pendingLock.unlock()

        os_log("Monitor service stopped", log: log, type: .info)
    }

    var isRunning: Bool {
        return webSocketServer?.running == true
    }

    var port: Int? {
        return serverPort
    }

    // MARK: - Trust Management

    func addTrustedPeer(peerJson: String) {
        do {
            let peer = try parseTrustedPeer(peerJson)
            if let certDer = peer.certDer {
                tlsManager?.addTrustedCert(certDer)
                os_log("Added trusted peer: %{public}@", log: log, type: .info, String(peer.fingerprint.prefix(12)))
            }
        } catch {
            os_log("Failed to add trusted peer: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    func removeTrustedPeer(fingerprint: String) {
        tlsManager?.removeTrustedCert(fingerprint: fingerprint)
        webSocketServer?.disconnectByFingerprint(fingerprint)
        os_log("Removed trusted peer: %{public}@", log: log, type: .info, String(fingerprint.prefix(12)))
    }

    // MARK: - Messaging

    func broadcast(messageJson: String) {
        webSocketServer?.broadcast(messageJson: messageJson)
    }

    func sendTo(connectionId: String, messageJson: String) {
        webSocketServer?.sendTo(connectionId: connectionId, messageJson: messageJson)
    }

    func respondHttp(requestId: String, statusCode: Int, bodyJson: String?) {
        pendingLock.lock()
        let responder = pendingHttpRequests.removeValue(forKey: requestId)
        pendingLock.unlock()

        if let responder = responder {
            responder(statusCode, bodyJson)
            os_log("HTTP response sent for %{public}@: %{public}d", log: log, type: .info, requestId, statusCode)
        } else {
            os_log("No pending HTTP request found for %{public}@", log: log, type: .error, requestId)
        }
    }

    // MARK: - Parsing Helpers

    private struct IdentityData {
        let deviceId: String
        let certDer: Data
        let privateKey: Data
        let fingerprint: String
    }

    private struct TrustedPeerData {
        let deviceId: String
        let fingerprint: String
        let certDer: Data?
    }

    private func parseIdentity(_ json: String) throws -> IdentityData {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorServiceError.invalidJson("Failed to parse identity JSON")
        }

        guard let deviceId = obj["deviceId"] as? String,
              let certDerBase64 = obj["certDer"] as? String,
              let privateKeyBase64 = obj["privateKey"] as? String,
              let fingerprint = obj["fingerprint"] as? String else {
            throw MonitorServiceError.invalidJson("Missing required identity fields")
        }

        guard let certDer = Data(base64Encoded: certDerBase64),
              let privateKey = Data(base64Encoded: privateKeyBase64) else {
            throw MonitorServiceError.invalidJson("Failed to decode base64 identity data")
        }

        return IdentityData(
            deviceId: deviceId,
            certDer: certDer,
            privateKey: privateKey,
            fingerprint: fingerprint
        )
    }

    private func parseTrustedPeers(_ json: String) throws -> [TrustedPeerData] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return arr.compactMap { obj in
            guard let fingerprint = obj["fingerprint"] as? String else { return nil }

            let deviceId = obj["deviceId"] as? String ?? ""
            var certDer: Data? = nil
            if let certDerBase64 = obj["certDer"] as? String, !certDerBase64.isEmpty {
                certDer = Data(base64Encoded: certDerBase64)
            }

            return TrustedPeerData(
                deviceId: deviceId,
                fingerprint: fingerprint,
                certDer: certDer
            )
        }
    }

    private func parseTrustedPeer(_ json: String) throws -> TrustedPeerData {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorServiceError.invalidJson("Failed to parse trusted peer JSON")
        }

        guard let fingerprint = obj["fingerprint"] as? String else {
            throw MonitorServiceError.invalidJson("Missing fingerprint in trusted peer")
        }

        let deviceId = obj["deviceId"] as? String ?? ""
        var certDer: Data? = nil
        if let certDerBase64 = obj["certDer"] as? String, !certDerBase64.isEmpty {
            certDer = Data(base64Encoded: certDerBase64)
        }

        return TrustedPeerData(
            deviceId: deviceId,
            fingerprint: fingerprint,
            certDer: certDer
        )
    }
}

// MARK: - Errors

enum MonitorServiceError: Error {
    case invalidJson(String)
}
