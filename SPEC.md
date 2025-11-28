# CribCall - Full Spec (LAN-only, mTLS + WebRTC)

**Version:** 0.3
**Platforms:** Android, Linux (Flutter); iOS planned

---

## 1. PRD / PRM - Product Requirements (What & Why)

### 1.1 Overview

**Product:** CribCall
**Purpose:** Local-network baby monitor app with:

- Sound-triggered alerts
- Live audio/video
- Strong local security (no cloud)

**Core constraints:**

- Works only when **monitor and listener are on the same LAN** (same Wi-Fi/ethernet).
- No remote/cloud backend for core functionality.
- Devices are linked with:
  - **QR code pairing** (certificate fingerprint in QR), and/or
  - **Numeric comparison pairing** (P-256 ECDH with 6-digit code verification).

- Devices exchange **P-256 ECDSA public keys** and use them for mTLS authentication.
- Control/signaling over **HTTP+WebSocket with mTLS**.
- Media (audio/video) over **WebRTC** (UDP).
- **FCM fallback** for noise alerts when listener app is backgrounded (optional, requires Firebase project).

---

### 1.2 Roles & Personas

**Roles**

- **Monitor device**
  - Placed in baby's room (phone/tablet/mini-PC).
  - Captures audio (and optionally video).
  - Runs sound detection.
  - Hosts mTLS HTTP+WebSocket control server and WebRTC peer.
  - Advertises presence via mDNS.

- **Listener device**
  - Parent's phone or Linux desktop.
  - Discovers monitors via mDNS and pairs with them.
  - Receives noise events over WebSocket (primary) or FCM (fallback).
  - Opens live audio/video streams via WebRTC.

**Personas**

1. **Anna – Non-technical parent**
   - Wants: “Set up once, it just works.”
   - Needs: clear “monitoring ON/OFF”, simple pairing, obvious alerts.

2. **Mark – Tech-savvy parent**
   - Wants: LAN-only, no cloud, clear security with keys & PIN.
   - Needs: configurable thresholds, reassurance that nothing leaves the network.

3. **Caregiver – Lightweight user**
   - Only uses listener mode.
   - Needs: easy pairing, one-tap “Listen” / “View video”.

---

### 1.3 Scope

**In scope (v1)**

- LAN-only monitoring.
- Sound detection:
  - Configurable threshold (0-100), minimum duration (ms), and cooldown (seconds).
  - Per-listener threshold/cooldown overrides.

- WebRTC streaming (audio or audio+video) over UDP.
- Pairing:
  - QR pairing (cert fingerprint + connection info in QR).
  - Numeric comparison pairing (P-256 ECDH with 6-digit verification code).

- P-256 ECDSA device identity with X.509 certificates.
- mTLS HTTP+WebSocket control channel (pairing, events, signaling).
- Background monitoring on monitor devices (Android foreground service).
- Local notifications on listener devices.
- FCM fallback for noise alerts when listener is backgrounded.
- Per-listener noise subscription with lease-based expiry.
- Input device selection and gain control (0-200%).
- Playback volume control on listener (0-200%).

**Out of scope (v1)**

- Internet / remote access (except FCM which uses Google infrastructure).
- Cloud services or user accounts.
- Cloud recording/history of media.
- Advanced AI / ML analysis.
- Smart home integrations.
- iOS platform (planned for v2).

---

### 1.4 Goals

1. **Zero-cloud, LAN-only**
   Everything stays on the home network. FCM is optional fallback only.

2. **Secure by design**
   - P-256 ECDSA keypairs for every device.
   - Pairing requires QR scan or numeric comparison verification.
   - All control traffic encrypted via mTLS.
   - WebRTC media encrypted (DTLS-SRTP).
   - Certificate fingerprint pinning before any connection.

3. **Reliable monitoring**
   - Continuous audio capture on monitor.
   - Android foreground service survives app backgrounding.
   - FCM fallback delivers alerts when WebSocket disconnected.
   - Automatic reconnection and subscription renewal.

4. **Simple pairing UX**
   - Non-technical users can pair with QR or numeric code easily.
   - Automatic mDNS discovery of monitors on LAN.

5. **Low-latency audio/video**
   - Sub-second latency on a normal LAN.

---

### 1.5 Core Use Cases

1. **Setup monitor**
   - Parent sets device as **Monitor**.
   - Gives it a name ("Nursery"), enables monitoring.
   - Monitor starts mDNS advertisement and control server.

2. **Pair listener via QR**
   - Monitor shows QR code with deviceId, certFingerprint, IP, ports.
   - Listener scans QR, pins certificate fingerprint, connects to pairing endpoint.
   - Both devices show 6-digit comparison code; user confirms match.
   - Listener added to monitor's trusted list.

3. **Pair listener via mDNS discovery**
   - Listener discovers monitor via mDNS browse.
   - Listener initiates pairing; both show 6-digit comparison code.
   - User confirms code match on both devices.
   - Keys exchanged and bound via P-256 ECDH.

4. **Sound-triggered alert**
   - Monitor detects noise exceeding threshold for min-duration.
   - Sends `NOISE_EVENT` over WebSocket to connected listeners.
   - For disconnected listeners with active subscriptions, sends FCM push.
   - Listener shows local notification and can open live audio.

5. **Manual live audio/video**
   - Listener opens app, taps "Listen" or "View video".
   - WebRTC stream negotiated via WebSocket control channel.

6. **Background monitoring**
   - Monitor: Android foreground service with notification.
   - Listener: Receives FCM alerts when app backgrounded.
   - Listener foreground service keeps WebSocket alive when streaming.

7. **Manage trusted listeners**
   - Monitor shows list of paired listener devices with online status.
   - Parent can revoke any device (triggers remote unpair).
   - Listener can forget monitor (sends unpair request first).

---

### 1.6 Functional Requirements

#### FR1 - Device Roles & Identity

- FR1.1: On first launch, app presents tab-based role selection: Monitor or Listener.
- FR1.2: Each installation generates:
  - `deviceId`: UUID v4
  - `devicePublicKey` / `devicePrivateKey`: P-256 ECDSA keypair

- FR1.3: Device stores keys securely (Android Keystore, iOS Keychain, Linux secure file).
- FR1.4: Each device creates a self-signed X.509 certificate with the P-256 public key.
- FR1.5: Canonical device identity is the **certificate fingerprint**: `certFingerprint = SHA-256(selfSignedCertDER)` as hex string. This value is pinned in QR/mDNS, pairing transcripts, and mTLS validation.
- FR1.6: All JSON used in security-sensitive contexts (pairing transcripts, HMAC inputs) is serialized using RFC 8785 (JCS) canonicalization.
- FR1.7: Device name is resolved from platform (Android Settings/Build, hostname on Linux).

#### FR2 - QR Pairing

- FR2.1: Monitor can display a QR code encoding JSON:
  - `remoteDeviceId`: UUID
  - `monitorName`: Display name
  - `certFingerprint`: SHA-256 hex over self-signed cert DER
  - `ips`: Array of IP addresses (IPv4/IPv6)
  - `controlPort`: mTLS WebSocket port
  - `pairingPort`: TLS pairing endpoint port
  - `version`: Protocol version

- FR2.2: Listener scans QR, pins `certFingerprint`, resolves IP from mDNS or uses QR IPs.
- FR2.3: Listener connects to `/pair/init` with TLS (server cert pinned), exchanges P-256 ECDH public keys.
- FR2.4: Both devices derive 6-digit comparison code from ECDH shared secret via HKDF-SHA256.
- FR2.5: User confirms code matches on both devices; listener sends `/pair/confirm` with HMAC auth tag.
- FR2.6: Monitor stores listener cert fingerprint; returns deviceId and monitor name.
- FR2.7: Fallback: If QR scanner unavailable, listener can paste QR JSON manually.

#### FR3 - mDNS Discovery + Numeric Comparison Pairing

- FR3.1: Monitor advertises via mDNS service type `_baby-monitor._tcp.local` with TXT records:
  - `remoteDeviceId`, `monitorName`, `certFingerprint`, `controlPort`, `pairingPort`, `version`, `transport`.

- FR3.2: Listener browses mDNS, lists discovered monitors with online/offline status (45s TTL timeout).
- FR3.3: When pairing via discovery:
  - Listener pins `certFingerprint` from mDNS advertisement.
  - Listener connects to `/pair/init` with TLS, server cert must match pinned fingerprint.
  - Both exchange P-256 ECDH public keys, derive 6-digit comparison code.
  - Both devices display comparison code; user confirms match on monitor.
  - Listener sends `/pair/confirm` with HMAC-SHA256 auth tag over pairing transcript.
  - Monitor verifies auth tag, stores listener cert fingerprint, returns success.

- FR3.4: Pairing fails if auth tag invalid, session expired (60s default), or fingerprint mismatch.
- FR3.5: Monitor shows pairing confirmation drawer with listener name and comparison code.

#### FR4 - Sound Detection

- FR4.1: Monitor continuously captures audio (16kHz mono PCM) and runs RMS-based sound detection.
- FR4.2: Configurable per monitor:
  - Threshold (0-100 scale).
  - Minimum duration (ms, e.g., 200, 400, 800).
  - Cooldown (seconds between events, e.g., 2, 4, 8).
  - Input device selection (platform-specific).
  - Input gain (0-200%).

- FR4.3: Per-listener subscription settings:
  - Individual threshold override.
  - Individual cooldown override.
  - Auto-stream type (none/audio/audio_video).
  - Auto-stream duration (seconds).

- FR4.4: When noise exceeds threshold for >= minDuration:
  - Generate `NoiseEvent` with timestamp and peakLevel.
  - Send `NOISE_EVENT` over WebSocket to connected listeners (filtered by subscription settings).
  - For listeners without active WebSocket but with valid FCM subscription, send FCM push.
  - FCM contains: type, monitorName, peakLevel, remoteDeviceId, timestamp.

- FR4.5: Noise subscription endpoints (mTLS required):
  - `POST /noise/subscribe`: Register FCM token with lease (default 24h, max capped).
  - `POST /noise/unsubscribe`: Remove subscription by token or subscriptionId.
  - Subscriptions bound to client certificate fingerprint; reject spoofed deviceIds.

#### FR5 - Audio/Video Streaming (WebRTC)

- FR5.1: Listener can request:
  - Audio-only (`audio`), or
  - Audio + video stream (`audio_video`) from a monitor.

- FR5.2: WebRTC implementation:
  - Flutter WebRTC plugin (flutter_webrtc).
  - UDP transport with DTLS-SRTP encryption.
  - Host-only ICE candidates (no public STUN/TURN by default).

- FR5.3: Signaling over WebSocket control channel:
  - `START_STREAM_REQUEST`: sessionId, mediaType
  - `WEBRTC_OFFER`: sessionId, sdp
  - `WEBRTC_ANSWER`: sessionId, sdp
  - `WEBRTC_ICE`: sessionId, candidate (JSON)
  - `END_STREAM`: sessionId
  - `PIN_STREAM`: sessionId (cancels auto-stop)

- FR5.4: Monitor may auto-start stream after `NOISE_EVENT` for configured duration.
- FR5.5: Listener may pin stream to keep it alive until manually ended.
- FR5.6: Playback volume control (0-200%) on listener side.

#### FR6 - Background Operation

- FR6.1: Monitor uses platform-appropriate background strategies:
  - Android: Foreground service (`AudioCaptureService`) with microphone type.
  - Android 15+: Falls back to `dataSync` foreground service type if microphone FGS denied.
  - Linux: Standard app process (minimize to tray optional).

- FR6.2: Monitor service handles:
  - Audio capture via `AudioRecord` (16kHz mono).
  - mDNS advertisement via NsdManager.
  - Control server via `MonitorService` foreground service.

- FR6.3: Listener background operation:
  - `ListenerService` foreground service with partial wake lock keeps WebSocket alive.
  - FCM receives noise events when app fully backgrounded.
  - Deduplication prevents duplicate handling of WebSocket + FCM events.

- FR6.4: Listener shows local notifications for noise events.
  - Per-monitor mute toggle suppresses notifications but keeps subscription active.
  - Notification actions: open app, dismiss.

#### FR7 - Settings & Management

- FR7.1: Monitor settings (persisted):
  - Device name.
  - Threshold (0-100), min duration (ms), cooldown (seconds).
  - Input device selection.
  - Input gain (0-200%).
  - Auto-stream type (none/audio/audio_video).
  - Auto-stream duration (seconds).

- FR7.2: Listener settings (persisted):
  - Enable/disable notifications.
  - Default action on noise event (notify vs auto-open stream).
  - Playback volume (0-200%).
  - Per-monitor overrides (threshold, cooldown, auto-stream).

- FR7.3: Trusted device management:
  - Monitor lists paired listeners with online status and FCM token presence.
  - Monitor can revoke listener (sends disconnect, removes from trust list).
  - Listener can forget monitor (sends `/unpair` request, removes local state).

- FR7.4: Noise subscription endpoints (mTLS required, local-only):
  - `POST /noise/subscribe`:
    - Body: `{fcmToken, platform, threshold?, cooldownSeconds?, autoStreamType?, autoStreamDurationSec?, leaseSeconds?}`
    - Returns: `{subscriptionId, deviceId, expiresAt, acceptedLeaseSeconds}`
    - Idempotent; newest token overwrites previous for device.
    - Lease clamped to default (24h) and max cap.
    - `ws-only:{deviceId}` token format for Linux without FCM.
  - `POST /noise/unsubscribe`:
    - Body: `{fcmToken?}` or `{subscriptionId?}`
    - Returns: `{deviceId, subscriptionId?, expiresAt?, unsubscribed}`
    - Idempotent even if not found.
  - `POST /unpair`:
    - Removes caller from trusted listeners.
    - Closes active connections.

- FR7.5: Session restoration:
  - App restores last role and connected monitor on launch.
  - Listener auto-subscribes to noise events on reconnect.
  - Subscription renewal at 50% of lease remaining.

---

### 1.7 Non-Functional Requirements

- NFR1 – Latency:
  - Audio < 300ms; audio+video < 800ms on typical LAN.

- NFR2 – Battery:
  - Monitor target < 8–10% battery/hour with screen off.

- NFR3 - Security:
  - P-256 ECDSA device identity.
  - mTLS with certificate fingerprint pinning.
  - DTLS-SRTP for media.
  - Canonical JSON (RFC 8785) for signed/HMAC'd payloads.
  - HMAC-SHA256 for pairing auth tags.

- NFR4 - Privacy:
  - No external servers for core functionality.
  - FCM used only for optional background noise alerts.
  - No audio/video stored on any server.

- NFR5 - Reliability:
  - Recovers gracefully from brief LAN drops.
  - Automatic reconnection with subscription renewal.
  - Dual delivery path (WebSocket + FCM) for noise events.

---

### 1.8 Risks

- iOS background restrictions (iOS not yet implemented).
- Android foreground service restrictions on newer API levels.
- WebRTC interop and stability across platforms.
- FCM dependency for background notifications (mitigated by WebSocket-only fallback).

---

## 2. SDD / TDD - System Design (How It Works)

### 2.1 Architecture Overview

**No central backend.** Everything happens on LAN between:

- **Monitor app instance**:
  - mTLS HTTP+WebSocket control server.
  - TLS pairing server (separate port).
  - mDNS advertiser.
  - Sound detection engine.
  - WebRTC sender.
  - FCM sender (for background alerts).

- **Listener app instance**:
  - mDNS browser.
  - mTLS WebSocket client.
  - WebRTC receiver.
  - FCM receiver (for background alerts).

**Flutter layer** (`lib/`):
- UI (Material Design)
- State management (Riverpod)
- Business logic and controllers
- WebRTC session management
- mTLS client implementation

**Android native layer** (`android/`):
- `AudioCaptureService`: Foreground service for mic + mDNS
- `MonitorService`: Foreground service for mTLS WebSocket server
- `MonitorTlsManager`: P-256 ECDSA certificate handling
- `ControlWebSocketServer`: WebSocket protocol implementation
- `ControlMessageCodec`: Length-prefixed JSON framing
- `ListenerService`: Keep-alive for background listening
- Platform channels for Flutter communication

**Linux layer**:
- PipeWire/PulseAudio subprocess for audio capture
- Raw multicast sockets for mDNS discovery
- Avahi subprocess for mDNS advertising
- Dart-based mTLS server (no native layer needed)

---

### 2.2 Identity & Keys

On first run:

1. Generate `deviceId` (UUID v4).
2. Create P-256 ECDSA keypair:
   - `devicePublicKey`, `devicePrivateKey`.

3. Build self-signed X.509 certificate (`deviceCert`) with:
   - P-256 public key in SPKI format.
   - Subject: `CN=CribCall Device`.
   - SubjectAltName: `URI:cribcall:{deviceId}`.
   - Validity: 10 years.

4. Compute fingerprint: `certFingerprint = SHA-256(deviceCertDER)` as lowercase hex string.

5. Store securely:
   - Android: SharedPreferences (encrypted) or Keystore.
   - iOS: Keychain.
   - Linux: `~/.local/share/cribcall/identity.json`.

6. Identity includes:
   - `deviceId`: UUID string
   - `certDer`: Base64-encoded certificate
   - `privateKeyDer`: Base64-encoded PKCS#8 private key
   - `fingerprint`: SHA-256 hex string

All devices use `deviceId` as their unique identifier. The `certFingerprint` is the canonical identity for pinning.

---

### 2.3 Pairing Protocols

#### 2.3.1 QR Pairing (Monitor to Listener)

1. Monitor constructs QR payload (JSON):

```json
{
  "remoteDeviceId": "M1-UUID",
  "monitorName": "Nursery",
  "certFingerprint": "abcd1234...",
  "ips": ["192.168.1.100", "fe80::1"],
  "controlPort": 48080,
  "pairingPort": 48081,
  "version": 1
}
```

2. Listener scans QR, pins `certFingerprint`.
3. Listener connects to `https://{ip}:{pairingPort}/pair/init` with TLS:
   - Server cert fingerprint **must** match pinned `certFingerprint`.
   - Request body:

```json
{
  "listenerName": "Dad's Phone",
  "listenerCertFingerprint": "efgh5678...",
  "ecdhPublicKey": "<base64 P-256 public key>"
}
```

4. Monitor responds:

```json
{
  "sessionId": "PS1-UUID",
  "monitorName": "Nursery",
  "ecdhPublicKey": "<base64 P-256 public key>",
  "expiresInSec": 60
}
```

5. Both devices derive 6-digit comparison code:
   - ECDH shared secret from P-256 key exchange.
   - `comparisonCode = HKDF-SHA256(sharedSecret, "cribcall-pair-code", 3 bytes) mod 1000000`.
   - Displayed as zero-padded 6 digits.

6. User confirms codes match on monitor (confirmation drawer).

7. Listener sends `POST /pair/confirm`:

```json
{
  "sessionId": "PS1-UUID",
  "authTag": "<base64 HMAC-SHA256>"
}
```

   - `authTag = HMAC-SHA256(pairingKey, canonical_json(transcript))`
   - `transcript = {sessionId, listenerCertFingerprint, monitorCertFingerprint}`
   - `pairingKey = HKDF-SHA256(comparisonCode, "cribcall-pair-key", 32 bytes)`

8. Monitor verifies auth tag, stores listener cert fingerprint, responds:

```json
{
  "remoteDeviceId": "M1-UUID",
  "monitorName": "Nursery",
  "certDer": "<base64 monitor certificate>"
}
```

9. Listener saves monitor as trusted. Future connections use mTLS with pinned fingerprints.

---

#### 2.3.2 mDNS Discovery + Numeric Comparison Pairing

1. **Discovery:**
   - Monitor advertises `_baby-monitor._tcp.local` with TXT records:
     - `remoteDeviceId`, `monitorName`, `certFingerprint`, `controlPort`, `pairingPort`, `version`, `transport`.

   - Listener browses mDNS, shows discovered monitors with online/offline status.
   - Listener pins `certFingerprint` from mDNS before connecting.

2. **Pairing flow identical to QR pairing steps 3-9.**

The only difference is how the listener obtains the initial connection info:
- QR: Scanned from monitor's screen.
- mDNS: Discovered via network broadcast.

Both use the same `/pair/init` and `/pair/confirm` endpoints with P-256 ECDH and 6-digit comparison code verification.

---

#### 2.3.3 QR Fallback (Manual JSON Entry)

If QR scanner unavailable (missing camera, unsupported platform):
1. User copies QR JSON from monitor screen.
2. Listener provides text input for pasting JSON.
3. Parser validates JSON structure and required fields.
4. Proceeds with normal pairing flow.

---

### 2.4 LAN Discovery (mDNS)

**Monitor side:**

- Advertise service `_baby-monitor._tcp.local` via:
  - Android: NsdManager
  - Linux: avahi-publish-service subprocess
- Service name: `{monitorName}-{remoteDeviceId}`
- TXT records:
  - `remoteDeviceId`: UUID
  - `monitorName`: Display name
  - `certFingerprint`: SHA-256 hex
  - `controlPort`: mTLS WebSocket port
  - `pairingPort`: TLS pairing port
  - `version`: Protocol version
  - `transport`: "http+ws"

**Listener side:**

- Browse `_baby-monitor._tcp.local` via:
  - Android: NsdManager
  - Linux: Raw multicast sockets (224.0.0.251:5353)
- Parse mDNS A/SRV/TXT records
- Cache with 45-second TTL timeout
- Emit online/offline events based on TTL expiry
- Show monitors as:
  - "Paired" (known `remoteDeviceId` in trusted list)
  - "Available" (unknown `remoteDeviceId`)

mDNS is for discovery only; trust is granted via pairing with numeric comparison.

---

### 2.5 mTLS Control Channel

#### 2.5.1 Transport

- HTTP/1.1 + WebSocket over TLS 1.2/1.3.
- Monitor hosts two servers:
  - **Pairing server** (TLS, no client cert required): `/pair/init`, `/pair/confirm`
  - **Control server** (mTLS, client cert required): `/control/ws`, `/health`, `/noise/*`, `/unpair`
- Both sides use self-signed P-256 ECDSA X.509 certificates.
- SHA-256 fingerprints are the canonical identities.

**Server pinning:** Client must verify server cert fingerprint matches pinned value from QR/mDNS before any request.

**Client auth (mTLS):** Control server requires valid client certificate. Certificate fingerprint must be in trusted listeners list. Unknown clients are rejected with 401/403.

**Platform implementations:**
- Android: `MonitorService` foreground service with `ControlWebSocketServer` and `MonitorTlsManager`
- Linux: Dart `HttpServer` with `SecurityContext`

#### 2.5.2 HTTP Endpoints

**Pairing endpoints (TLS, no client cert):**
- `POST /pair/init`: Start pairing, exchange ECDH keys
- `POST /pair/confirm`: Complete pairing with auth tag

**Control endpoints (mTLS required):**
- `GET /health`: Returns `{"status":"ok"}`
- `GET /control/ws`: WebSocket upgrade for real-time messaging
- `POST /noise/subscribe`: Register FCM token for notifications
- `POST /noise/unsubscribe`: Remove FCM subscription
- `POST /unpair`: Remove caller from trusted list

#### 2.5.3 WebSocket Framing

Messages are length-prefixed JSON:
- 4-byte length `L` (big-endian, network order)
- `L` bytes of UTF-8 JSON

Example encoded message:
```
00 00 00 21 {"type":"PING","timestamp":123}
```

#### 2.5.4 Message Types

**Noise events:**
- `NOISE_EVENT`: `{type, deviceId, timestamp, peakLevel}`

**Stream control:**
- `START_STREAM_REQUEST`: `{type, sessionId, mediaType}`
- `START_STREAM_RESPONSE`: `{type, sessionId, accepted, reason?}`
- `END_STREAM`: `{type, sessionId}`
- `PIN_STREAM`: `{type, sessionId}`

**WebRTC signaling:**
- `WEBRTC_OFFER`: `{type, sessionId, sdp}`
- `WEBRTC_ANSWER`: `{type, sessionId, sdp}`
- `WEBRTC_ICE`: `{type, sessionId, candidate}`

**FCM token sync:**
- `FCM_TOKEN_UPDATE`: `{type, deviceId, fcmToken}`

**Keep-alive:**
- `PING`: `{type, timestamp?}`
- `PONG`: `{type, timestamp?}`

#### 2.5.5 Error Handling

- Invalid JSON: Close WebSocket with 1002 (protocol error)
- Unknown message type: Log warning, ignore
- Auth failure: HTTP 401/403, close connection
- Certificate mismatch: Detect and report to user (monitor may have been reinstalled)
- Unsupported message: send `UNSUPPORTED_MESSAGE`; close stream for untrusted clients, keep open for trusted.
---

### 2.6 WebRTC Media (Audio/Video)

Use Flutter WebRTC plugin (`flutter_webrtc`).

**Roles:**

- Monitor = sending audio track, optional video track (camera).
- Listener = receiving tracks.

**ICE config:**

- `iceServers: []` by default (LAN-only, no public STUN/TURN).
- Host candidates only to keep media on local network.

```dart
final config = RTCConfiguration(
  iceServers: [],
  iceTransportPolicy: RTCIceTransportPolicy.all,
  sdpSemantics: 'unified-plan',
);
```

**Codecs:**

- Audio: Opus at 48 kHz, mono, 24-32 kbps target.
- Video: H.264 baseline/high (hardware-accelerated), 720p @ 30fps max.

**Signaling via WebSocket:**

1. Listener sends `START_STREAM_REQUEST`:
```json
{"type": "START_STREAM_REQUEST", "sessionId": "S123", "mediaType": "audio"}
```

2. Monitor creates peer connection, adds tracks, sends offer:
```json
{"type": "WEBRTC_OFFER", "sessionId": "S123", "sdp": "v=0..."}
```

3. Listener sets remote description, creates answer:
```json
{"type": "WEBRTC_ANSWER", "sessionId": "S123", "sdp": "v=0..."}
```

4. Both exchange ICE candidates via `WEBRTC_ICE`.

5. Media flows over UDP (DTLS-SRTP).

**Auto-stop:**

- Auto-initiated streams (from `NOISE_EVENT`) have configurable duration.
- Listener can send `PIN_STREAM` to keep stream alive indefinitely.
- `END_STREAM` terminates the session.

---

### 2.7 Sound Detection Engine

**Audio capture (monitor):**

- Android: `AudioRecord` in `AudioCaptureService` foreground service.
- Linux: PipeWire subprocess (`pw-record`) or PulseAudio.

**Configuration:**

- Sample rate: 16,000 Hz
- Channels: Mono
- Format: PCM 16-bit signed, little-endian
- Frame size: ~640 bytes (~20ms)

**Algorithm:**

1. For each audio frame, compute RMS:
   ```
   RMS = sqrt(mean(sample^2))
   ```

2. Map RMS to level [0-100] with optional gain (0-200%).

3. Track loud frames:
   - If `level >= threshold`: increment `loudFrames`
   - Else: reset `loudFrames = 0`

4. Trigger noise event when:
   - `loudFrames * frameDurationMs >= minDurationMs`
   - Not in cooldown period

5. Enter cooldown after event (configurable seconds).

**Per-listener filtering:**

- Each subscription can override threshold and cooldown.
- Events filtered before delivery based on subscription settings.

---

### 2.8 Background Behaviour

**Android (Monitor)**

- `AudioCaptureService`: Foreground service with `FOREGROUND_SERVICE_TYPE_MICROPHONE`.
  - Android 15+: Falls back to `FOREGROUND_SERVICE_TYPE_DATA_SYNC` if mic FGS denied.
  - Persistent notification: "Monitoring {monitorName}".
  - Captures audio via `AudioRecord`.
  - Advertises via NsdManager.

- `MonitorService`: Foreground service with `FOREGROUND_SERVICE_TYPE_DATA_SYNC`.
  - Hosts mTLS WebSocket server.
  - Manages trusted peer connections.

**Android (Listener)**

- `ListenerService`: Foreground service with partial wake lock.
  - Keeps WebSocket connection alive when backgrounded.
  - Notification: "Connected to {monitorName}".

- FCM handles noise alerts when app fully terminated.

**Linux**

- Standard app process (no special background handling needed).
- Optional: minimize to system tray.

---

### 2.9 Data Storage

**Monitor storage:**

- `identity.json`: deviceId, certDer, privateKeyDer, fingerprint
- `trusted_listeners.json`: Array of {deviceId, fingerprint, name, fcmToken?, createdAt}
- `monitor_settings.json`: threshold, minDuration, cooldown, inputDevice, inputGain, autoStreamType, autoStreamDuration
- `noise_subscriptions.json`: Per-listener FCM token subscriptions with expiry

**Listener storage:**

- `identity.json`: deviceId, certDer, privateKeyDer, fingerprint
- `trusted_monitors.json`: Array of {remoteDeviceId, name, fingerprint, lastKnownIp, controlPort, pairingPort}
- `listener_settings.json`: notificationsEnabled, defaultAction, playbackVolume
- `per_monitor_settings.json`: Per-monitor threshold/cooldown overrides
- `app_session.json`: lastRole, monitoringEnabled, lastConnectedMonitorId

**Storage locations:**

- Android: SharedPreferences (encrypted where available)
- Linux: `~/.local/share/cribcall/`

Deleting identity clears all trust anchors; device must be re-paired.

---

### 2.10 Testing Strategy

**Unit tests:**
- Sound detection (thresholds, min-duration, cooldown)
- Pairing (ECDH key exchange, comparison code derivation, auth tag verification)
- Control message serialization/parsing
- RFC 8785 canonicalization
- Certificate fingerprint computation
- mTLS pinning validation

**Integration tests:**
- Two devices on LAN: QR pairing, numeric comparison pairing
- Noise event delivery (WebSocket and FCM paths)
- WebRTC signaling with host-only candidates
- Subscription lifecycle (subscribe, renew, unsubscribe)
- Unpair flow (local and remote)

**Manual tests:**
- Audio latency on various Wi-Fi configurations
- Background behavior (screen off, app switch, force stop)
- FCM delivery when app terminated
- mDNS discovery across subnets

---

## 3. UI/UX & Design System (How It Looks)

### 3.1 UX Principles

- Calm, reassuring, simple.
- Clear state: monitoring active vs inactive.
- Clear indication that everything is local (no cloud).
- Tab-based role switching (Monitor/Listener).

---

### 3.2 Flows & Screens (Summary)

**Role Selection (Tab-based)**

- Tab 0: Monitor - "Use as Monitor (in baby's room)"
- Tab 1: Listener - "Use as Listener (on parent device)"
- Settings button in AppBar for role-specific configuration.
- Device fingerprint chip for identity verification.

**Monitor Dashboard**

- Monitor name and status toggle (Monitoring: ON/OFF).
- Audio waveform visualization with real-time levels.
- Trusted listeners list with online/offline status.
- Pairing QR code sheet.
- Settings: threshold slider, min-duration/cooldown dropdowns, input device picker, gain slider.

**Monitor - Pairing Confirmation Drawer**

- Listener name requesting pairing.
- 6-digit comparison code (large display).
- Confirm/Reject buttons.
- Expiry countdown timer.

**Listener Dashboard**

- Trusted monitors list with online/offline indicators.
- Last noise event timestamp per monitor.
- Connection status to selected monitor.
- Stream controls when connected.
- Per-monitor settings sheet for threshold/cooldown overrides.

**Listener - Pairing Flow**

- QR scanner page (with manual JSON fallback).
- Comparison code display after scan.
- "Waiting for confirmation" state.
- Success/failure feedback.

**Live Stream View**

- Audio waveform or video player.
- "Live" badge with duration.
- Volume control slider.
- Pin stream button (keep alive).
- End stream button.
- Local connection indicator.

---

### 3.3 Design System

**Colors:**
- Primary: `#3B82F6`
- Background: `#F9FAFB`
- Surface: `#FFFFFF`
- Text primary: `#111827`
- Success: `#10B981`
- Error: `#EF4444`

**Components:**
- Rounded cards (radius 16px), subtle shadow.
- Status badges (online/offline/connecting).
- Metric rows for settings display.
- Custom sliders for thresholds/volume.

**Typography:**
- H1: 24px semi-bold
- H2: 18px semi-bold
- Body: 14-16px regular
- Font: Google Fonts (system default fallback)

**Accessibility:**
- WCAG AA contrast ratios.
- 44x44px minimum touch targets.
- VoiceOver/TalkBack labels for all interactive elements.
- High contrast mode support.
