import Foundation
import Network
import CryptoKit
import os.log

/// WebSocket server with HTTP endpoint support, running over mTLS.
/// Handles the control protocol for monitor-listener communication.
class ControlWebSocketServer {
    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "ws_server")

    private let port: UInt16
    private let tlsManager: MonitorTlsManager

    private var listener: NWListener?
    private var connections: [String: WebSocketConnection] = [:]
    private let connectionsLock = NSLock()
    private var connectionIdCounter = 0
    private var isRunning = false

    // Callbacks (matching Android)
    var onClientConnected: ((String, String, String) -> Void)?       // connectionId, fingerprint, remoteAddress
    var onClientDisconnected: ((String, String?) -> Void)?           // connectionId, reason
    var onWsMessage: ((String, String) -> Void)?                     // connectionId, messageJson
    var onHttpRequest: ((String, String, String, String?, String?, @escaping (Int, String?) -> Void) -> Void)?
        // requestId, method, path, fingerprint, body, responder

    private var pendingHttpRequests: [String: (Int, String?) -> Void] = [:]
    private var requestIdCounter = 0

    init(port: UInt16, tlsManager: MonitorTlsManager) {
        self.port = port
        self.tlsManager = tlsManager
    }

    // MARK: - Server Lifecycle

    func start() throws {
        if isRunning {
            os_log("Server already running", log: log, type: .info)
            return
        }

        os_log("Starting server on port %{public}d", log: log, type: .info, port)

        // Create TLS parameters
        let tlsOptions = tlsManager.createTlsOptions()

        // Create TCP parameters with TLS
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.acceptLocalOnly = false
        parameters.allowLocalEndpointReuse = true

        // Create listener
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: DispatchQueue.global(qos: .userInitiated))
        isRunning = true

        os_log("Server started on port %{public}d", log: log, type: .info, port)
    }

    func stop() {
        guard isRunning else { return }

        os_log("Stopping server", log: log, type: .info)

        isRunning = false

        // Close all connections
        connectionsLock.lock()
        for (_, connection) in connections {
            connection.close(reason: "server_shutdown")
        }
        connections.removeAll()
        connectionsLock.unlock()

        // Cancel listener
        listener?.cancel()
        listener = nil

        os_log("Server stopped", log: log, type: .info)
    }

    var running: Bool {
        return isRunning
    }

    // MARK: - State Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            os_log("Server listener ready", log: log, type: .info)
        case .failed(let error):
            os_log("Server listener failed: %{public}@", log: log, type: .error, error.localizedDescription)
            isRunning = false
        case .cancelled:
            os_log("Server listener cancelled", log: log, type: .info)
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let remoteEndpoint = connection.endpoint
        let remoteAddr = remoteEndpoint.debugDescription

        os_log("New connection from %{public}@", log: log, type: .info, remoteAddr)

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(connection, state: state, remoteAddr: remoteAddr)
        }

        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func handleConnectionState(_ connection: NWConnection, state: NWConnection.State, remoteAddr: String) {
        switch state {
        case .ready:
            os_log("Connection ready from %{public}@", log: log, type: .info, remoteAddr)
            // Wait for HTTP request
            readHttpRequest(connection: connection, remoteAddr: remoteAddr)

        case .failed(let error):
            os_log("Connection failed: %{public}@", log: log, type: .error, error.localizedDescription)
            connection.cancel()

        case .cancelled:
            os_log("Connection cancelled", log: log, type: .info)

        default:
            break
        }
    }

    // MARK: - HTTP Request Parsing

    private func readHttpRequest(connection: NWConnection, remoteAddr: String) {
        // Read initial HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                os_log("Read error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                os_log("Empty request", log: self.log, type: .info)
                connection.cancel()
                return
            }

            self.parseHttpRequest(data: data, connection: connection, remoteAddr: remoteAddr)
        }
    }

    private func parseHttpRequest(data: Data, connection: NWConnection, remoteAddr: String) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendHttpError(connection: connection, statusCode: 400, message: "Invalid request encoding")
            return
        }

        // Find the end of headers (double CRLF)
        guard let headerEndRange = requestString.range(of: "\r\n\r\n") else {
            sendHttpError(connection: connection, statusCode: 400, message: "Malformed request")
            return
        }

        let headersSection = String(requestString[..<headerEndRange.lowerBound])
        let lines = headersSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            sendHttpError(connection: connection, statusCode: 400, message: "Empty request")
            return
        }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else {
            sendHttpError(connection: connection, statusCode: 400, message: "Invalid request line")
            return
        }

        let method = requestLine[0]
        let path = requestLine[1]

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Get client fingerprint from TLS metadata
        let fingerprint = getClientFingerprint(connection: connection)

        os_log(
            "Request: %{public}@ %{public}@ from %{public}@ fp=%{public}@",
            log: log,
            type: .info,
            method,
            path,
            remoteAddr,
            fingerprint?.prefix(12).description ?? "none"
        )

        // Calculate how much body we already have vs how much we need
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStartIndex = requestString.index(headerEndRange.upperBound, offsetBy: 0)
        let bodyAlreadyReceived = String(requestString[bodyStartIndex...])
        let bodyBytesReceived = bodyAlreadyReceived.utf8.count

        os_log(
            "Content-Length: %{public}d, body received: %{public}d",
            log: log,
            type: .debug,
            contentLength,
            bodyBytesReceived
        )

        if contentLength > 0 && bodyBytesReceived < contentLength {
            // Need to read more body data
            let remaining = contentLength - bodyBytesReceived
            os_log("Reading remaining body: %{public}d bytes", log: log, type: .debug, remaining)

            readRemainingBody(
                connection: connection,
                method: method,
                path: path,
                headers: headers,
                fingerprint: fingerprint,
                bodyPrefix: bodyAlreadyReceived,
                remaining: remaining,
                remoteAddr: remoteAddr
            )
        } else {
            // Body complete (or no body)
            let body: String? = contentLength > 0 ? bodyAlreadyReceived : nil

            // Route request
            routeRequest(
                connection: connection,
                method: method,
                path: path,
                headers: headers,
                fingerprint: fingerprint,
                body: body,
                remoteAddr: remoteAddr
            )
        }
    }

    private func readRemainingBody(
        connection: NWConnection,
        method: String,
        path: String,
        headers: [String: String],
        fingerprint: String?,
        bodyPrefix: String,
        remaining: Int,
        remoteAddr: String
    ) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                os_log("Error reading body: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.sendHttpError(connection: connection, statusCode: 400, message: "Failed to read body")
                return
            }

            var fullBody = bodyPrefix
            if let data = data, let chunk = String(data: data, encoding: .utf8) {
                fullBody += chunk
            }

            os_log("Full body received: %{public}d bytes", log: self.log, type: .debug, fullBody.utf8.count)

            self.routeRequest(
                connection: connection,
                method: method,
                path: path,
                headers: headers,
                fingerprint: fingerprint,
                body: fullBody,
                remoteAddr: remoteAddr
            )
        }
    }

    private func getClientFingerprint(connection: NWConnection) -> String? {
        // Get TLS metadata
        guard let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            os_log("No TLS metadata available for connection", log: log, type: .debug)
            return nil
        }

        // Access the security protocol metadata
        let secMetadata = tlsMetadata.securityProtocolMetadata

        // Extract client certificate fingerprint from peer certificate chain
        // Note: sec_protocol_metadata_access_peer_certificate_chain calls the handler synchronously
        var fingerprint: String? = nil

        sec_protocol_metadata_access_peer_certificate_chain(secMetadata) { certChain in
            // Get the first certificate (client cert)
            let certCount = sec_certificate_chain_get_count(certChain)
            guard certCount > 0,
                  let certRef = sec_certificate_chain_get_certificate(certChain, 0) else {
                return
            }

            let cert = sec_certificate_copy_ref(certRef).takeRetainedValue()

            if let certData = SecCertificateCopyData(cert) as Data? {
                fingerprint = MonitorTlsManager.fingerprintHex(certData)
            }
        }

        return fingerprint
    }

    // MARK: - Request Routing

    private func routeRequest(
        connection: NWConnection,
        method: String,
        path: String,
        headers: [String: String],
        fingerprint: String?,
        body: String?,
        remoteAddr: String
    ) {
        // Check for WebSocket upgrade
        if path == "/control/ws" && isWebSocketUpgrade(headers: headers) {
            handleWebSocketUpgrade(
                connection: connection,
                headers: headers,
                fingerprint: fingerprint,
                remoteAddr: remoteAddr
            )
            return
        }

        // Health endpoint
        if path == "/health" {
            sendHttpResponse(connection: connection, statusCode: 200, body: "{\"status\":\"ok\"}")
            return
        }

        // Forward other requests to Dart
        requestIdCounter += 1
        let requestId = "req-\(requestIdCounter)"

        onHttpRequest?(requestId, method, path, fingerprint, body) { [weak self] statusCode, responseBody in
            self?.sendHttpResponse(connection: connection, statusCode: statusCode, body: responseBody)
        }
    }

    private func isWebSocketUpgrade(headers: [String: String]) -> Bool {
        return headers["upgrade"]?.lowercased() == "websocket" &&
               headers["connection"]?.lowercased().contains("upgrade") == true
    }

    // MARK: - WebSocket Upgrade

    private func handleWebSocketUpgrade(
        connection: NWConnection,
        headers: [String: String],
        fingerprint: String?,
        remoteAddr: String
    ) {
        // Require valid client certificate for WebSocket
        // Note: The TLS verify block already validated the certificate
        // If we got here, the client is trusted

        guard let wsKey = headers["sec-websocket-key"] else {
            os_log("WebSocket rejected: missing Sec-WebSocket-Key", log: log, type: .error)
            sendHttpError(connection: connection, statusCode: 400, message: "missing_websocket_key")
            return
        }

        // Compute accept key
        let acceptKey = computeWebSocketAccept(key: wsKey)

        // Send upgrade response
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r

        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                os_log("Failed to send upgrade response: %{public}@", log: self.log, type: .error, error.localizedDescription)
                connection.cancel()
                return
            }

            // Create WebSocket connection
            self.connectionIdCounter += 1
            let connectionId = "ws-\(self.connectionIdCounter)"

            let wsConnection = WebSocketConnection(
                connectionId: connectionId,
                fingerprint: fingerprint ?? "unknown",
                remoteAddress: remoteAddr,
                nwConnection: connection,
                onMessage: { [weak self] msg in
                    self?.onWsMessage?(connectionId, msg)
                },
                onClose: { [weak self] reason in
                    self?.connectionsLock.lock()
                    self?.connections.removeValue(forKey: connectionId)
                    self?.connectionsLock.unlock()
                    self?.onClientDisconnected?(connectionId, reason)
                }
            )

            self.connectionsLock.lock()
            self.connections[connectionId] = wsConnection
            self.connectionsLock.unlock()

            self.onClientConnected?(connectionId, fingerprint ?? "unknown", remoteAddr)

            // Start reading WebSocket frames
            wsConnection.startReading()
        })
    }

    private func computeWebSocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = Insecure.SHA1.hash(data: combined.data(using: .utf8)!)
        return Data(hash).base64EncodedString()
    }

    // MARK: - HTTP Response Helpers

    private func sendHttpResponse(connection: NWConnection, statusCode: Int, body: String?) {
        let statusText = httpStatusText(statusCode)
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"

        if let body = body {
            let bodyData = body.data(using: .utf8) ?? Data()
            response += "Content-Length: \(bodyData.count)\r\n"
            response += "\r\n"
            response += body
        } else {
            response += "Content-Length: 0\r\n"
            response += "\r\n"
        }

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHttpError(connection: NWConnection, statusCode: Int, message: String) {
        sendHttpResponse(connection: connection, statusCode: statusCode, body: "{\"error\":\"\(message)\"}")
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    // MARK: - WebSocket Operations

    func broadcast(messageJson: String) {
        let frame = encodeWebSocketFrame(text: messageJson)

        connectionsLock.lock()
        let conns = Array(connections.values)
        connectionsLock.unlock()

        for conn in conns {
            conn.sendFrame(frame)
        }
    }

    func sendTo(connectionId: String, messageJson: String) {
        connectionsLock.lock()
        let conn = connections[connectionId]
        connectionsLock.unlock()

        guard let connection = conn else {
            os_log("Connection not found: %{public}@", log: log, type: .error, connectionId)
            return
        }

        let frame = encodeWebSocketFrame(text: messageJson)
        connection.sendFrame(frame)
    }

    func disconnectByFingerprint(_ fingerprint: String) {
        connectionsLock.lock()
        let toDisconnect = connections.values.filter { $0.fingerprint == fingerprint }
        connectionsLock.unlock()

        for conn in toDisconnect {
            os_log("Disconnecting %{public}@ (peer removed)", log: log, type: .info, conn.connectionId)
            conn.close(reason: "peer_removed")
        }
    }

    // MARK: - WebSocket Frame Encoding

    private func encodeWebSocketFrame(text: String) -> Data {
        let payload = text.data(using: .utf8) ?? Data()
        var frame = Data()

        // FIN + Text opcode
        frame.append(0x81)

        // Length (no mask for server->client)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}

// MARK: - WebSocket Connection

class WebSocketConnection {
    let connectionId: String
    let fingerprint: String
    let remoteAddress: String

    private let connection: NWConnection
    private let onMessage: (String) -> Void
    private let onClose: (String?) -> Void
    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "ws_conn")

    private var isClosed = false

    init(
        connectionId: String,
        fingerprint: String,
        remoteAddress: String,
        nwConnection: NWConnection,
        onMessage: @escaping (String) -> Void,
        onClose: @escaping (String?) -> Void
    ) {
        self.connectionId = connectionId
        self.fingerprint = fingerprint
        self.remoteAddress = remoteAddress
        self.connection = nwConnection
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func startReading() {
        readFrame()
    }

    private func readFrame() {
        guard !isClosed else { return }

        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                os_log("Read error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.close(reason: "read_error")
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.close(reason: "connection_closed")
                }
                return
            }

            self.parseFrame(data: data)
            self.readFrame()
        }
    }

    private func parseFrame(data: Data) {
        guard data.count >= 2 else { return }

        let bytes = [UInt8](data)
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var payloadLength = Int(bytes[1] & 0x7F)
        var offset = 2

        // Extended length
        if payloadLength == 126 {
            guard data.count >= 4 else { return }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if payloadLength == 127 {
            guard data.count >= 10 else { return }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | Int(bytes[2 + i])
            }
            offset = 10
        }

        // Masking key (client->server is always masked)
        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { return }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        // Payload
        guard data.count >= offset + payloadLength else { return }
        var payload = Array(bytes[offset..<(offset + payloadLength)])

        // Unmask if needed
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        // Handle opcode
        switch opcode {
        case 0x01: // Text frame
            if let text = String(bytes: payload, encoding: .utf8) {
                os_log("Received message: %{public}@", log: log, type: .debug, String(text.prefix(100)))
                onMessage(text)
            }

        case 0x08: // Close frame
            close(reason: "client_close")

        case 0x09: // Ping
            sendPong(payload: Data(payload))

        case 0x0A: // Pong
            break // Ignore

        default:
            os_log("Unknown opcode: %{public}d", log: log, type: .info, opcode)
        }
    }

    func sendFrame(_ frame: Data) {
        guard !isClosed else { return }

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error = error {
                os_log("Send error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
            }
        })
    }

    private func sendPong(payload: Data) {
        var frame = Data()
        frame.append(0x8A) // FIN + Pong
        frame.append(UInt8(payload.count))
        frame.append(payload)
        sendFrame(frame)
    }

    func close(reason: String?) {
        guard !isClosed else { return }
        isClosed = true

        os_log("Closing connection %{public}@: %{public}@", log: log, type: .info, connectionId, reason ?? "unknown")

        // Send close frame
        var frame = Data()
        frame.append(0x88) // FIN + Close
        frame.append(0x00) // No payload
        sendFrame(frame)

        connection.cancel()
        onClose(reason)
    }
}
