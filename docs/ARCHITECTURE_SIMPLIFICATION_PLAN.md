# Architecture Simplification: TLS Reverse Proxy Approach

## Problem Statement

Currently, the control server has two separate implementations:

1. **Dart** (`lib/src/control/control_server.dart`) - 900 lines
   - Used on Linux, macOS, iOS, Windows
   - Full mTLS HTTP+WebSocket server using `dart:io` `HttpServer.bindSecure()`
   - Handles all endpoints: `/health`, `/test`, `/unpair`, `/noise/subscribe`, `/noise/unsubscribe`, `/control/ws`

2. **Kotlin** (`android/app/src/main/kotlin/.../ControlWebSocketServer.kt`) - 411 lines + supporting files
   - Used on Android only
   - Full mTLS HTTP+WebSocket server using raw `SSLServerSocket`
   - Same endpoints, reimplemented in Kotlin
   - Required because Android foreground services need native networking for reliability

**Total duplicated protocol code: ~1,300+ lines across both platforms**

### Why This Is Problematic

- Protocol changes require edits in two languages
- Bug fixes must be applied twice
- Testing surface area doubled
- Subtle behavioral differences possible between implementations

---

## Proposed Solution: Option A - Minimal TLS Proxy

Replace the full Kotlin server with a thin TLS termination proxy that forwards to Dart.

### New Architecture

```
CURRENT (Android):
  Remote Client
       |
       | (mTLS)
       v
  Kotlin ControlWebSocketServer (TLS + HTTP parsing + WS framing + routing)
       |
       | (platform channels - events & method calls)
       v
  Dart AndroidControlServer (business logic dispatcher)
       |
       v
  Dart ControlServerController (actual business logic)


PROPOSED (Android):
  Remote Client
       |
       | (mTLS)
       v
  Kotlin TlsProxyServer (TLS termination ONLY)
       |
       | (plaintext TCP to localhost, with X-Client-Fingerprint header)
       v
  Dart ControlServer (HTTP + WS + business logic - SAME code as other platforms)
```

### What Kotlin TlsProxyServer Does

1. Accept incoming TLS connections on external port (e.g., 48080)
2. Validate client certificate against trusted list
3. Extract client certificate fingerprint
4. Open plaintext TCP connection to localhost Dart server (e.g., 127.0.0.1:48081)
5. Inject `X-Client-Fingerprint: <sha256hex>` header into HTTP request
6. Bidirectionally proxy all bytes between client and Dart server
7. Handle connection lifecycle (timeouts, errors, cleanup)

### What Kotlin TlsProxyServer Does NOT Do

- Parse HTTP beyond injecting one header
- Understand WebSocket framing
- Route requests to different handlers
- Implement any business logic
- Manage application state

---

## Detailed Implementation Plan

### Phase 1: Create TlsProxyServer.kt

**New file:** `android/app/src/main/kotlin/com/cribcall/cribcall/TlsProxyServer.kt`

**Estimated size:** 150-200 lines

```kotlin
class TlsProxyServer(
    private val externalPort: Int,
    private val internalPort: Int,  // Dart server port on localhost
    private val tlsManager: MonitorTlsManager
) {
    private var serverSocket: SSLServerSocket? = null
    private var running = AtomicBoolean(false)
    private val executor = Executors.newCachedThreadPool()

    fun start() { ... }
    fun stop() { ... }

    private fun acceptLoop() {
        while (running.get()) {
            val clientSocket = serverSocket?.accept() as? SSLSocket ?: continue
            executor.execute { handleConnection(clientSocket) }
        }
    }

    private fun handleConnection(clientSocket: SSLSocket) {
        // 1. Complete TLS handshake
        clientSocket.startHandshake()

        // 2. Validate and extract client fingerprint
        val fingerprint = tlsManager.validateClientCert(clientSocket)
        if (fingerprint == null || !tlsManager.isTrusted(fingerprint)) {
            clientSocket.close()
            return
        }

        // 3. Connect to local Dart server (plaintext)
        val dartSocket = Socket("127.0.0.1", internalPort)

        // 4. Start proxying with header injection
        proxyConnection(clientSocket, dartSocket, fingerprint)
    }

    private fun proxyConnection(
        client: SSLSocket,
        dart: Socket,
        fingerprint: String
    ) {
        // Read first line of HTTP request
        // Inject X-Client-Fingerprint header after first line
        // Then bidirectionally copy streams until either closes
    }
}
```

**Key implementation details:**

- Header injection happens only once at connection start (before first \r\n\r\n)
- After headers, pure byte copying in both directions
- WebSocket upgrade handled transparently (it's just HTTP upgrade then raw frames)
- Two threads per connection: client->dart and dart->client

### Phase 2: Modify Dart ControlServer

**File:** `lib/src/control/control_server.dart`

**Changes:**

1. Add option to bind plaintext (for localhost from proxy):

```dart
Future<void> start({
  required int port,
  required DeviceIdentity identity,
  required List<TrustedPeer> trustedPeers,
  bool plaintextLocalhost = false,  // NEW: for Android proxy mode
}) async {
  if (plaintextLocalhost) {
    // Bind without TLS - only accepts from localhost
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  } else {
    // Existing TLS bind
    final context = await _buildSecurityContext(identity);
    _server = await HttpServer.bindSecure(...);
  }
}
```

2. Extract client fingerprint from header when in proxy mode:

```dart
Future<void> _handleRequest(HttpRequest request) async {
  String? clientFingerprint;

  if (_plaintextLocalhost) {
    // Get fingerprint from proxy header
    clientFingerprint = request.headers.value('X-Client-Fingerprint');
  } else {
    // Get fingerprint from TLS client certificate
    final clientCert = request.certificate;
    if (clientCert != null) {
      clientFingerprint = _fingerprintHex(clientCert.der);
    }
  }

  // Rest of handling uses clientFingerprint...
}
```

3. Add validation that plaintext mode only accepts localhost connections:

```dart
if (_plaintextLocalhost) {
  final remoteIp = request.connectionInfo?.remoteAddress;
  if (remoteIp != null && !remoteIp.isLoopback) {
    _log('Rejecting non-localhost connection in proxy mode');
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return;
  }
}
```

### Phase 3: Update AndroidControlServer

**File:** `lib/src/control/android_control_server.dart`

**Changes:**

This file becomes much simpler - it just needs to:
1. Start the Kotlin TLS proxy via platform channel
2. Start the Dart ControlServer in plaintext localhost mode
3. No more event translation needed (Dart server handles everything)

```dart
class AndroidControlServer {
  static const _methodChannel = MethodChannel('cribcall/tls_proxy');

  ControlServer? _dartServer;
  int? _externalPort;
  int? _internalPort;

  Future<void> start({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    _externalPort = port;
    _internalPort = port + 1;  // e.g., 48080 external, 48081 internal

    // 1. Start Dart server on localhost (plaintext)
    _dartServer = ControlServer();
    await _dartServer!.start(
      port: _internalPort!,
      identity: identity,
      trustedPeers: trustedPeers,
      plaintextLocalhost: true,
    );

    // 2. Start Kotlin TLS proxy
    await _methodChannel.invokeMethod('startProxy', {
      'externalPort': _externalPort,
      'internalPort': _internalPort,
      'identityJson': _serializeIdentity(identity),
      'trustedPeersJson': _serializeTrustedPeers(trustedPeers),
    });
  }

  // Events come directly from _dartServer.events - no translation needed!
  Stream<ControlServerEvent> get events => _dartServer?.events ?? const Stream.empty();
}
```

### Phase 4: Update MonitorService.kt

**File:** `android/app/src/main/kotlin/com/cribcall/cribcall/MonitorService.kt`

**Changes:**

- Replace `ControlWebSocketServer` with `TlsProxyServer`
- Remove all HTTP request handling callbacks
- Remove all WebSocket message callbacks
- Keep only: start proxy, stop proxy, update trusted peers

```kotlin
class MonitorService : Service() {
    private var tlsManager: MonitorTlsManager? = null
    private var proxyServer: TlsProxyServer? = null

    fun startProxy(externalPort: Int, internalPort: Int, identityJson: String, trustedPeersJson: String) {
        val identity = parseIdentity(identityJson)
        val trustedPeers = parseTrustedPeers(trustedPeersJson)

        tlsManager = MonitorTlsManager(
            serverCertDer = identity.certDer,
            serverPrivateKey = identity.privateKey,
            trustedPeerCerts = trustedPeers.mapNotNull { it.certDer }
        )

        proxyServer = TlsProxyServer(
            externalPort = externalPort,
            internalPort = internalPort,
            tlsManager = tlsManager!!
        )
        proxyServer?.start()
    }

    fun stopProxy() {
        proxyServer?.stop()
        proxyServer = null
        tlsManager = null
    }

    fun addTrustedPeer(peerJson: String) {
        val peer = parseTrustedPeer(JSONObject(peerJson))
        tlsManager?.addTrustedCert(peer.certDer)
    }

    fun removeTrustedPeer(fingerprint: String) {
        tlsManager?.removeTrustedCert(fingerprint)
    }
}
```

### Phase 5: Cleanup

**Files to delete or simplify:**

1. `ControlWebSocketServer.kt` - DELETE (replaced by TlsProxyServer.kt)
2. `WebSocketFrameCodec.kt` - DELETE (Dart handles WebSocket)
3. `WebSocketConnection.kt` - DELETE (Dart handles connections)
4. `HttpResponseWriter.kt` - DELETE (Dart handles HTTP)
5. `ControlMessageCodec.kt` - DELETE (Dart handles message framing)

**Estimated code reduction:**
- Kotlin: ~800 lines removed, ~200 lines added = **-600 lines**
- Dart: ~50 lines added for proxy mode support

---

## Files Changed Summary

| File | Action | Lines |
|------|--------|-------|
| `TlsProxyServer.kt` | CREATE | +150-200 |
| `ControlWebSocketServer.kt` | DELETE | -411 |
| `WebSocketFrameCodec.kt` | DELETE | -130 |
| `WebSocketConnection.kt` | DELETE | -91 |
| `HttpResponseWriter.kt` | DELETE | -48 |
| `ControlMessageCodec.kt` | DELETE | -85 |
| `MonitorService.kt` | SIMPLIFY | -150 |
| `control_server.dart` | MODIFY | +50 |
| `android_control_server.dart` | SIMPLIFY | -150 |

**Net change: approximately -1,000 lines**

---

## Risk Assessment

### Low Risk
- Dart `HttpServer.bind()` works on Android when app is in foreground
- Localhost TCP is reliable and fast
- Header injection is simple and well-understood

### Medium Risk
- Dart server must stay alive in Android foreground service context
- Need to verify `HttpServer` reliability in Android background scenarios
- WebSocket long-polling behavior through proxy

### Mitigation
- Keep Kotlin foreground service for process lifecycle (already working)
- Dart server runs in same process, just different thread
- Test extensively with backgrounding, doze mode, etc.

---

## Testing Plan

1. **Unit tests**
   - TlsProxyServer header injection
   - ControlServer plaintext mode fingerprint extraction
   - Localhost-only validation

2. **Integration tests**
   - Full flow: remote client -> TLS proxy -> Dart server
   - WebSocket upgrade through proxy
   - Long-lived WebSocket connections
   - Multiple concurrent connections

3. **Platform tests**
   - Android foreground/background transitions
   - Android doze mode behavior
   - Battery optimization impact
   - Network switching (WiFi -> mobile)

4. **Regression tests**
   - All existing control protocol tests should pass
   - No behavior change visible to remote clients

---

## Rollback Plan

Keep the old Kotlin implementation in a `deprecated/` folder during transition. If issues arise:
1. Revert `MonitorService.kt` to use `ControlWebSocketServer`
2. Revert `android_control_server.dart` to event-based model
3. Delete `TlsProxyServer.kt`

---

## Questions for Review

1. Should the internal port be configurable or always external+1?
2. Should we add a health check endpoint on the proxy itself?
3. Do we need connection limits on the proxy?
4. Should proxy log all connections or only errors?
5. Timeout values for proxy connections?

---

## Alternative Considered: Option B & C

### Option B: Use Existing Reverse Proxy Library
- Libraries like `littleproxy` exist for Java/Kotlin
- Adds dependency, potentially heavy for this use case
- Less control over header injection behavior
- **Rejected:** Too heavy, less maintainable than custom 150-line proxy

### Option C: Keep Both Implementations, Generate from Spec
- Define protocol in OpenAPI/protobuf
- Generate both Dart and Kotlin implementations
- **Rejected:** Adds build complexity, still maintaining two codebases, protocol is simple enough that generation overhead not worth it
