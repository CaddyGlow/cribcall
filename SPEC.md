# CribCall – Full Spec (LAN-only, QUIC + WebRTC)

**Version:** 0.2
**Platforms:** Android, iOS, Linux (Flutter)

---

## 1. PRD / PRM – Product Requirements (What & Why)

### 1.1 Overview

**Product:** CribCall
**Purpose:** Local-network baby monitor app with:

- Sound-triggered alerts
- Live audio/video
- Strong local security (no cloud)

**Core constraints:**

- Works only when **monitor and listener are on the same LAN** (same Wi-Fi/ethernet).
- No remote/cloud backend.
- Devices are linked with:
  - **QR code pairing**, and/or
  - **mDNS/UPnP discovery + PIN pairing**.

- Devices exchange **public keys** and use them for authentication.
- Control/signaling over **QUIC**.
- Media (audio/video) over **WebRTC** (UDP).

---

### 1.2 Roles & Personas

**Roles**

- **Monitor device**
  - Placed in baby’s room (phone/tablet/mini-PC).
  - Captures audio (and optionally video).
  - Runs sound detection.
  - Hosts QUIC control server and WebRTC peer.

- **Listener device**
  - Parent’s phone or Linux desktop.
  - Discovers & pairs with monitors.
  - Receives noise events and opens streams.

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
  - Configurable threshold & minimum duration.

- WebRTC streaming (audio or audio+video) over UDP.
- Pairing:
  - QR pairing (cert fingerprint included in QR).
  - mDNS discovery + PIN pairing (to protect key exchange from MITM).

- Public-key device identity & trust lists.
- QUIC-based control channel (pairing, events, signaling).
- Background monitoring on monitor devices (within OS limits).
- Local notifications on listener devices.

**Out of scope (v1)**

- Internet / remote access.
- Cloud services or user accounts.
- Cloud recording/history of media.
- Push notifications via FCM/APNs (beyond local notifications).
- Advanced AI / ML analysis.
- Smart home integrations.

---

### 1.4 Goals

1. **Zero-cloud, LAN-only**
   Everything stays on the home network.

2. **Secure by design**
   - Long-term keypairs for every device.
   - Pairing requires QR or PIN.
   - All control traffic encrypted (QUIC/TLS).
   - WebRTC media encrypted (DTLS-SRTP).

3. **Reliable monitoring**
   - Continuous audio capture on monitor.
   - Robust to brief network interruptions.

4. **Simple pairing UX**
   - Non-technical users can pair with QR or PIN easily.

5. **Low-latency audio/video**
   - Sub-second latency on a normal LAN.

---

### 1.5 Core Use Cases

1. **Setup monitor**
   - Parent sets device as **Monitor**.
   - Gives it a name (“Nursery”), enables monitoring.

2. **Pair listener via QR**
   - Monitor shows QR code.
   - Listener scans QR and instantly trusts that monitor.

3. **Pair listener via mDNS + PIN**
   - Listener discovers monitor via LAN scan.
   - Monitor shows PIN; listener enters it.
   - Keys are exchanged and bound to that PIN to prevent MITM.

4. **Sound-triggered alert**
   - Monitor detects noise (crying).
   - Sends `NOISE_EVENT` over QUIC to listeners.
   - Listener shows notification and can open live audio.

5. **Manual live audio/video**
   - Listener opens app, taps “Listen” or “View video”.
   - WebRTC stream is negotiated via QUIC control channel.

6. **Background monitoring**
   - Monitor continues listening when screen is off.
   - Listener can receive alerts when app is backgrounded but still active.

7. **Manage trusted listeners**
   - Monitor shows list of paired listener devices.
   - Parent can revoke any device.

---

### 1.6 Functional Requirements

#### FR1 – Device Roles & Identity

- FR1.1: On first launch, app asks: “Use as Monitor” or “Use as Listener.”
- FR1.2: Each installation generates:
  - `deviceId`: UUID
  - `devicePublicKey` / `devicePrivateKey` (e.g. Ed25519)

- FR1.3: Device stores keys securely (Keystore/Keychain/secured file).
- FR1.4: Each device also creates a self-signed X.509 certificate with the device public key (Ed25519 SPKI).
- FR1.5: Canonical device identity is the **certificate fingerprint**: `certFingerprint = SHA-256(selfSignedCertDER)`. This value is what gets pinned in QR/mDNS, pairing transcripts, and QUIC validation (SPKI equivalence is acceptable, but fingerprint is the transport form).
- FR1.6: All JSON used in security-sensitive contexts (pairing transcripts, HMAC inputs) is serialized using RFC 8785 (JCS) canonicalization to avoid field-order/whitespace ambiguities.

#### FR2 – QR Pairing

- FR2.1: Monitor can display a QR code encoding:
  - `monitorId`
  - `monitorName`
  - `monitorCertFingerprint` (SHA-256 over self-signed cert DER)
  - Optional: `monitorPublicKey` (base64 SPKI) for human inspection/debugging
  - Service info (`protocol`, `version`, `defaultPort`)

- FR2.2: Listener scans QR → pins `monitorCertFingerprint` immediately (physical out-of-band).
- FR2.3: Listener establishes QUIC connection, verifies the server cert fingerprint matches `monitorCertFingerprint`, then sends `PAIR_REQUEST`. Client cert is allowed to be “unknown” only for pairing flows.
- FR2.4: Monitor stores listener as trusted (including listener cert fingerprint) and returns `PAIR_ACCEPTED`. Future QUIC sessions from that listener must present the pinned cert fingerprint.

#### FR3 – mDNS + PIN Pairing

- FR3.1: Monitor advertises itself via mDNS/UPnP with:
  - `monitorName`, `monitorId`, `monitorCertFingerprint`, `servicePort`, `version`.

- FR3.2: Listener scans LAN, lists discovered monitors, and pins `monitorCertFingerprint` before opening QUIC.
- FR3.3: When pairing via discovery:
  - Listener initiates PIN pairing (`PIN_PAIRING_INIT` over QUIC). Server cert **must** match pinned `monitorCertFingerprint`; client cert may be unknown for this flow only.
  - Monitor generates random PIN, shows it on screen, and sends `PIN_REQUIRED` with `pairingSessionId` + PAKE `pakeMsgA` (and expiry/attempt limit).
  - User enters PIN on listener; listener runs the PAKE with `pakeMsgA`, derives `pairingKey`, and sends `PIN_SUBMIT` containing `pakeMsgB` plus an auth tag over the transcript.
  - The PAKE transcript **includes the server cert fingerprint** observed in this QUIC session to bind the PIN to the specific server identity.
  - Monitor completes the PAKE, verifies the auth tag, stores listener (including listener cert fingerprint), sends `PAIR_ACCEPTED`.

- FR3.4: Pairing fails if PIN/auth fails, session expired, attempts exceeded, or server cert fingerprint in transcript does not equal the monitor’s own fingerprint.

#### FR4 – Sound Detection

- FR4.1: Monitor continuously captures audio and runs RMS-based sound detection.
- FR4.2: Configurable per monitor:
  - Threshold (0–100 or pseudo-dB).
  - Minimum duration (ms).
  - Cooldown (seconds between events).

- FR4.3: When noise exceeds threshold for ≥ minDuration:
  - Generate `NoiseEvent`.
  - Send `NOISE_EVENT` message on QUIC channel to connected listeners.

#### FR5 – Audio/Video Streaming (WebRTC)

- FR5.1: Listener can request:
  - Audio-only, or
  - Audio + video stream from a monitor.

- FR5.2: WebRTC is used:
  - Native WebRTC libs via Flutter plugin.
  - UDP transport (DTLS-SRTP).

- FR5.3: Signaling (offer/answer/ICE) goes over QUIC control channel.
- FR5.4: Monitor may auto-start an audio stream after `NOISE_EVENT` for X seconds (if configured).
- FR5.5: Listener may “pin” stream to cancel auto-stop and keep streaming until manually ended.

#### FR6 – Background Operation

- FR6.1: Monitor uses platform-appropriate background strategies:
  - Android: foreground service with notification.
  - iOS: background audio mode.

- FR6.2: If monitoring stops due to OS, user is clearly informed when reopening the app.
- FR6.3: Listener shows local notifications for noise events when app is backgrounded but running.

#### FR7 – Settings & Management

- FR7.1: Monitor settings:
  - Name, threshold, min duration, cooldown.
  - Auto-stream type (none/audio/audio+video).
  - Auto-stream duration.

- FR7.2: Listener settings:
  - Enable/disable notifications.
  - Default action when `NOISE_EVENT` received (notify vs auto-open stream).

- FR7.3: Monitor can list paired listeners and revoke them.

---

### 1.7 Non-Functional Requirements

- NFR1 – Latency:
  - Audio < 300ms; audio+video < 800ms on typical LAN.

- NFR2 – Battery:
  - Monitor target < 8–10% battery/hour with screen off.

- NFR3 – Security:
  - Public-key-based device identity.
  - QUIC/TLS with mutual TLS for control.
  - DTLS-SRTP for media.
  - Canonical JSON (RFC 8785) for signed/HMAC’d payloads.

- NFR4 – Privacy:
  - No external servers or third-party cloud.

- NFR5 – Reliability:
  - Recovers gracefully from brief LAN drops.

---

### 1.8 Risks

- iOS background restrictions.
- Complexity of cryptography and QUIC on mobile.
- WebRTC interop and stability across platforms.

---

## 2. SDD / TDD – System Design (How It Works)

### 2.1 Architecture Overview

**No central backend.** Everything happens on LAN between:

- **Monitor app instance**:
  - QUIC server.
  - mDNS advertiser.
  - Sound detection engine.
  - WebRTC sender.

- **Listener app instance**:
  - mDNS client.
  - QUIC client.
  - WebRTC receiver.

Flutter is used for:

- UI
- State management (e.g. Riverpod/Bloc)
- High-level logic

Native layers handle:

- QUIC
- WebRTC
- Audio capture
- Background work
- mDNS/UPnP

---

### 2.2 Identity & Keys

On first run:

1. Generate `deviceId` (UUID).
2. Create keypair, e.g. Ed25519:
   - `devicePublicKey`, `devicePrivateKey`.

3. Build self-signed X.509 certificate (`deviceCert`) with the SPKI from `devicePublicKey`.

4. Compute fingerprint: `certFingerprint = SHA-256(deviceCertDER)` → hex string. This fingerprint is the canonical identity used in QR/mDNS, transcripts, and pinning. (SPKI equality is acceptable as an implementation detail.)

5. Store securely:
   - Android: Keystore.
   - iOS: Keychain.
   - Linux: local encrypted file if possible.

Monitor has `monitorId` = `deviceId`.
Listener has `listenerId` = `deviceId`.

---

### 2.3 Pairing Protocols

#### 2.3.1 QR Pairing (Monitor → Listener)

1. Monitor constructs QR payload:

```json
{
  "type": "monitor_pair_v1",
  "monitorId": "M1-UUID",
  "monitorName": "Nursery",
  "monitorCertFingerprint": "hex-sha256",
  "monitorPublicKey": "<base64>", // optional, informational
  "service": {
    "protocol": "baby-monitor",
    "version": 1,
    "defaultPort": 48080
  }
}
```

2. Listener scans QR → obtains monitor cert fingerprint & service info.
3. Listener discovers monitor IP via mDNS/UPnP or local ARP.
4. Listener establishes QUIC connection to monitor’s IP:port with **server pinning**:
   - Server cert fingerprint **must** match `monitorCertFingerprint` from QR.
   - Client presents its device cert. For pairing messages, monitor accepts unknown client certs but restricts them to pairing-only message types. Post-pairing the monitor pins the listener’s cert fingerprint and requires it for all future sessions.
5. Listener performs `PAIR_REQUEST` over QUIC control stream:

```json
{
  "type": "PAIR_REQUEST",
  "listenerId": "L1-UUID",
  "listenerName": "Dad’s Phone",
  "listenerPublicKey": "<base64>",
  "listenerCertFingerprint": "hex-sha256"
}
```

6. Monitor stores listener as trusted and replies:

```json
{
  "type": "PAIR_ACCEPTED",
  "monitorId": "M1-UUID"
}
```

7. Listener saves monitor as trusted (`monitorId`, `monitorCertFingerprint`, name, IP). Monitor saves listener cert fingerprint so future QUIC sessions require that identity.

Since QR gives the public key out-of-band, no PIN needed.

---

#### 2.3.2 mDNS + PIN Pairing (No QR)

1. **Discovery:**
   - Monitor advertises `_baby-monitor._tcp.local` with:
     - `monitorId`, `monitorName`, `monitorCertFingerprint`, `servicePort`, `version`.

   - Listener browses mDNS and lists available monitors.
   - Listener must pin `monitorCertFingerprint` from the advertisement before opening QUIC.

2. **Start pairing: Listener → Monitor**

```json
{
  "type": "PIN_PAIRING_INIT",
  "listenerId": "L1-UUID",
  "listenerName": "Dad’s Phone",
  "protocolVersion": 1,
  "listenerCertFingerprint": "hex-sha256"
}
```

3. **Monitor generates:**

- `pairingSessionId` (UUID)
- `pin` (random 6-digit numeric, displayed later)
- `pakeMsgA` (first message for the PAKE over X25519 using the PIN as password)
- `expiry` (e.g. 60s) and `maxAttempts` (e.g. 3)

Stores mapping `{pairingSessionId → (PIN, pakeState, expiry, attemptsRemaining)}`.

4. **Monitor sends:**

```json
{
  "type": "PIN_REQUIRED",
  "pairingSessionId": "PS1-UUID",
  "pakeMsgA": "<base64>",
  "expiresInSec": 60,
  "maxAttempts": 3
}
```

And **displays PIN** on monitor UI.

5. **User enters PIN on Listener.**

6. **Listener runs PAKE:**

   - Uses the entered PIN and `pakeMsgA` to compute `pakeMsgB` and derive a shared `pairingKey` (X25519-derived session key).
   - Builds transcript:

```json
{
  "monitorId": "M1-UUID",
  "listenerId": "L1-UUID",
  "listenerPublicKey": "<base64>",
  "listenerCertFingerprint": "hex-sha256",
  "monitorCertFingerprint": "hex-sha256",
  "pairingSessionId": "PS1-UUID"
}
```

7. Listener authenticates transcript with the PAKE key:

```text
authTag = HMAC( pairingKey, serialize(transcript) )
```

8. **Listener → Monitor:**

```json
{
  "type": "PIN_SUBMIT",
  "pairingSessionId": "PS1-UUID",
  "pakeMsgB": "<base64>",
  "transcript": { ... },
  "authTag": "<base64>"
}
```

9. **Monitor verifies:**

- Runs the PAKE step with stored PIN and `pakeMsgB` to derive `pairingKey`.
- Verifies `authTag` over transcript.
- Verifies the `monitorCertFingerprint` in the transcript equals its own certificate fingerprint (binding the PAKE to the QUIC server identity).
- Decrements `attemptsRemaining`; rejects and expires after `maxAttempts` or timeout.

If OK:

- Store `listenerPublicKey` and data.
- Send:

```json
{
  "type": "PAIR_ACCEPTED",
  "monitorId": "M1-UUID"
}
```

Else:

```json
{
  "type": "PAIR_REJECTED",
  "reason": "INVALID_PIN" | "EXPIRED" | "INTERNAL_ERROR"
}
```

10. Listener saves monitor as trusted (monitorId, monitorCertFingerprint, name, lastKnownIp).

Now the monitor’s cert fingerprint is bound to this PIN-verified transcript, preventing MITM on same LAN.
PAKE prevents offline brute-forcing of the PIN; sessions expire after `expiresInSec` and are locked after `maxAttempts`.

#### 2.3.3 PAKE Implementation Choice

- Algorithm: X25519 ephemeral key agreement with HKDF-SHA256, binding the PIN into the HKDF info string.
- Messages: `pakeMsgA`/`pakeMsgB` are base64-encoded X25519 public keys.
- Authentication: `authTag = HMAC-SHA256(pairingKey, serialize(transcript))`.
- PIN policy: 6 digits, 60s expiry, max 3 attempts per `pairingSessionId`; session state cleared on expiry or lockout.
- Serialization: transcript JSON is canonicalized via RFC 8785 (JCS) to avoid key-order/whitespace mismatches between platforms.

---

### 2.4 LAN Discovery (mDNS / UPnP)

**Monitor side:**

- Advertise service `_baby-monitor._tcp.local`.
- TXT records / metadata:
  - `monitorId`, `monitorName`, `monitorCertFingerprint`, `version`.

**Listener side:**

- Browse `_baby-monitor._tcp.local`.
- Map services to monitors and show them as:
  - “Paired” (known `monitorId`).
  - “Unpaired” (unknown `monitorId`).

mDNS advertisement is for discovery only; trust is granted via QR or PIN pairing.

---

### 2.5 QUIC Control Channel

#### 2.5.1 Transport

- QUIC over UDP with TLS.
- Monitor acts as **server** on `servicePort`.
- Listener acts as **client**.
- Both sides present self-signed X.509 certs built from their Ed25519 device keys; SHA-256 fingerprints are the canonical identities.
- Certs include `subjectAltName: URI:cribcall:<deviceId>`; fingerprints are computed over the DER cert.
- **Server pinning:** client must verify server cert fingerprint matches the pinned `monitorCertFingerprint` from QR/mDNS before sending any control traffic.
- **Client auth bootstrap:** monitor accepts unknown client certs only for pairing-related message types; all other message types require the client cert fingerprint to be present in the trusted listeners list. After pairing, the monitor pins the listener fingerprint and rejects unknown clients.
- **Error handling:** QUIC control stream uses application-level error codes. On invalid/malformed frames, send `PROTOCOL_ERROR` and close the control stream. On authentication/pin failures, send `UNAUTHORIZED` and close. Unexpected message types yield `UNSUPPORTED_MESSAGE` but keep the stream open for trusted clients; for untrusted clients, close after error to limit probing.

#### 2.5.2 Streams & Framing

- Use one **bidirectional stream** for control (`controlStream`).
- When the client is not yet trusted, only pairing messages (`PAIR_REQUEST`, `PIN_*`) are processed; other message types are rejected.
- Messages are JSON, with length prefix:
  - 4-byte length `L` (big-endian)
  - `L` bytes of UTF-8 JSON

Example message:

```json
{
  "type": "NOISE_EVENT",
  "monitorId": "M1-UUID",
  "timestamp": 1234567890,
  "peakLevel": 85
}
```

#### 2.5.3 Message Types

- Pairing:
  - `PAIR_REQUEST`, `PAIR_ACCEPTED`, `PAIR_REJECTED`
  - `PIN_PAIRING_INIT`, `PIN_REQUIRED`, `PIN_SUBMIT`, `PAIR_REJECTED`

- Noise:
  - `NOISE_EVENT`

- Stream control:
  - `START_STREAM_REQUEST`, `START_STREAM_RESPONSE`, `END_STREAM`, `PIN_STREAM`

- WebRTC signaling:
  - `WEBRTC_OFFER`, `WEBRTC_ANSWER`, `WEBRTC_ICE`

- Health:
  - `PING`, `PONG`

**Protocol rules & errors:**
- Canonicalization: control JSON that participates in signing/HMAC (e.g., transcripts) uses RFC 8785.
- Framing errors: If length prefix is invalid or JSON parse fails, send `PROTOCOL_ERROR` and close control stream.
- Authorization errors: If a non-trusted client sends non-pairing messages, respond `UNAUTHORIZED` then close.
- Unsupported message: send `UNSUPPORTED_MESSAGE`; close stream for untrusted clients, keep open for trusted.
- Idempotency: `END_STREAM` is idempotent; duplicate `START_STREAM_REQUEST` with same `sessionId` should be rejected with `CONFLICT`.
- Non-paired clients may only send pairing messages (after server pinning succeeds); all other control traffic requires mTLS with a pinned listener fingerprint. QUIC handshakes are dropped if server pinning fails.

**Error codes (application-level):**

- `0`: `OK` (no error).
- `1`: `PROTOCOL_ERROR` (framing/JSON invalid).
- `2`: `UNAUTHORIZED` (pinning/auth/trust failure).
- `3`: `UNSUPPORTED_MESSAGE` (type not recognized for this role/state).
- `4`: `CONFLICT` (duplicate sessionId or conflicting state).
- `5`: `INTERNAL_ERROR` (unexpected server failure).

**Example framed messages:**

- Length-prefixed JSON over control stream. For a `PING` message:

  - JSON: `{"type":"PING","timestamp":123}` (canonical form already minimal).
  - Length = 33 bytes = `0x00 0x00 0x00 0x21`.
  - Frame bytes: `00 00 00 21 7b 22 74 79 70 65 22 3a 22 50 49 4e 47 22 2c 22 74 69 6d 65 73 74 61 6d 70 22 3a 31 32 33 7d`.

---

### 2.6 WebRTC Media (Audio/Video)

Use Flutter WebRTC plugin (native WebRTC libs).

**Roles:**

- Monitor = sending audio track, optional video track (camera).
- Listener = receiving tracks.

**ICE config:**

- `iceServers: []` by default (or a LAN-only STUN if needed for multi-subnet).
- Prefer/force host candidates to keep media LAN-only; disable default public STUN/TURN.
- Example (Flutter):

```dart
final config = RTCConfiguration(
  iceServers: [], // no default public STUN/TURN
  iceTransportPolicy: RTCIceTransportPolicy.all, // host candidates only when no STUN
  sdpSemantics: 'unified-plan',
);
final pc = await createPeerConnection(config);
```

**Codecs:**

- Audio: Opus at 48 kHz, mono, 24–32 kbps target; FEC on, DTX enabled when supported. Prefer RTP payload type negotiation that keeps Opus as first.
- Video: If video enabled, prefer H.264 baseline/high (hardware-accelerated) with 720p @ ≤30fps cap. Fallback to VP8 if H.264 unsupported. Bitrate target 1–2 Mbps on Wi-Fi; renegotiate lower on bandwidth constraint.
- Content Hint: `RTCVideoTrack` contentHint “motion” for camera feed to balance motion/detail.
- Resolution adaptation: allow downscale to 480p on weak links.

**Signaling via QUIC:**

1. Listener sends `START_STREAM_REQUEST`:

```json
{
  "type": "START_STREAM_REQUEST",
  "sessionId": "S123",
  "mediaType": "audio" | "audio_video"
}
```

2. Monitor checks:
   - Listener is in trusted list.
   - Resource limits.

3. If accepted, Monitor:

- Creates WebRTC peer connection.
- Adds tracks.
- Creates SDP offer.
- Sends:

```json
{
  "type": "WEBRTC_OFFER",
  "sessionId": "S123",
  "sdp": "v=0..."
}
```

4. Listener sets remote description, creates answer, sends:

```json
{
  "type": "WEBRTC_ANSWER",
  "sessionId": "S123",
  "sdp": "v=0..."
}
```

5. Both sides exchange ICE candidates via `WEBRTC_ICE`.

Media flows over UDP (DTLS-SRTP), fully separate from QUIC’s UDP usage.

**Auto-stop:**

- Monitor tracks whether stream is auto-initiated (due to `NOISE_EVENT`) or user-initiated.
- If auto-initiated, start timer for `autoStreamDurationSec`.
- Before stopping, send `STREAM_ENDING_SOON` or rely on `END_STREAM` with countdown UI on listener.
- If listener sends `PIN_STREAM`, cancel timer.

---

### 2.7 Sound Detection Engine

**Audio capture (monitor):**

- Android: `AudioRecord` in Foreground Service.
- iOS: `AVAudioEngine` / `AVAudioSession` tap.
- Linux: system-specific capture via plugin (PulseAudio/ALSA).

**Algorithm:**

- Sample rate 16kHz (or 48kHz downsampled).
- Frame size e.g. 320 samples (~20 ms).
- For each frame:
  1. Compute RMS:

     ```text
     RMS = sqrt( mean( sample^2 ) )
     ```

  2. Map RMS to “level” [0–100].
  3. If `level >= threshold`: `loudFrames++` else `loudFrames = 0`.
  4. If `loudFrames * frameDurationMs >= minDurationMs` and not in cooldown:
     - Trigger NoiseEvent.
     - Enter cooldown period.

---

### 2.8 Background Behaviour

**Android (Monitor)**

- Foreground Service:
  - Persistent notification (“Monitoring Nursery”).

- Holds mic, runs sound detection.
- Can start/stop WebRTC from service or via Flutter platform channel.

**iOS (Monitor)**

- Enable Background Audio capability.
- Use `AVAudioSession` with `.playAndRecord` or `.record`.
- Keep `AVAudioEngine` running in background with input tap.
- Need careful App Store justification: “baby monitor”.

**Linux**

- Just keep app running; optionally support minimize-to-tray.

---

### 2.9 Data Storage

**Monitor:**

- `deviceId`, keypair.
- `deviceCert`, `certFingerprint`.
- Trusted listeners (ID, public key, cert fingerprint, nickname, createdAt).
- Settings (threshold, minDuration, cooldown, auto-stream).

**Listener:**

- `deviceId`, keypair.
- `deviceCert`, `certFingerprint`.
- Trusted monitors (monitorId, name, cert fingerprint, lastKnownIp).
- Listener preferences.

Deleting a device key (monitor or listener) clears its trust anchors; the device must be re-paired to resume use.

---

### 2.10 Testing Strategy

- Unit tests:
  - Sound detection.
  - Pairing logic (PAKE success, wrong PIN fails, lockout/expiry enforced).
  - Control message serialization/parsing.
  - mTLS pinning and bootstrap:
    - Server pin check required before pairing messages proceed.
    - Untrusted clients can send pairing messages but cannot send post-pairing commands.
  - PAKE transcript binding to server cert fingerprint (mismatch should fail).
  - RFC 8785 canonicalization tests for transcripts and any HMAC’d payloads.

- Integration tests:
  - Two devices on same LAN: pairing (QR & PIN), NoiseEvent → stream.
  - QUIC control connection fails with unknown listener cert; succeeds post-pairing.
  - WebRTC offer/answer works with `iceServers: []` and host-only candidates.

- Manual tests:
  - Latency & quality on different Wi-Fi setups.
  - Background behavior (screen off, switch apps).

---

## 3. UI/UX & Design System (How It Looks)

### 3.1 UX Principles

- Calm, reassuring, simple.
- Clear state: monitoring active vs inactive.
- Clear indication that everything is local (no cloud).

---

### 3.2 Flows & Screens (Summary)

**Role Selection**

- “Use as Monitor (in baby’s room)”
- “Use as Listener (on parent device)”

**Monitor Home**

- Monitor name, status: “Monitoring: ON/OFF”
- Sound level bar, status text (Quiet/Noise).
- Buttons:
  - “Start/Stop monitoring”
  - “Show pairing QR”
  - “Paired devices”

**Monitor – Pairing QR**

- Full-screen QR.
- Info: monitor name, short ID, note “Use Listener to scan this on same Wi-Fi.”

**Monitor – PIN Display**

- When mDNS pairing in progress:
  - Big 6-digit PIN.
  - Text: “Enter this PIN on the Listener device.”
  - Timer (e.g. 60s).

**Listener Home (empty)**

- “No monitors paired yet.”
- Buttons:
  - “Scan QR code”
  - “Scan network”

**Listener – Scan Network**

- Progress indicator.
- Cards:
  - `Nursery – Unpaired monitor on MyHomeWiFi` → “Pair with PIN”
  - Or `Nursery – Paired monitor` → “Open”

**Listener – PIN Entry**

- Screen with 6-digit numeric input.
- “Enter PIN shown on monitor.”
- Error message on failure.

**Listener – Monitor Card**

- Name, status (Online/Offline).
- Last noise (“3 min ago”).
- Buttons: “Listen”, “View video”, menu “Forget monitor”.

**Live View**

- Video or audio visualizer.
- Badge “Live • 00:23”.
- Controls: mute, toggle video, “Keep live”, End call.
- Status: “Local connection — nothing leaves your home network.”

---

### 3.3 Design System (Short)

- **Primary color:** `#3B82F6`
- **Background:** `#F9FAFB`
- **Surface:** `#FFFFFF`
- **Text primary:** `#111827`
- Rounded cards (radius 16+), subtle shadow.
- Typography:
  - H1: 24 semi-bold.
  - H2: 18 semi-bold.
  - Body: 14–16 regular.

- Accessibility:
  - WCAG AA contrast.
  - 44x44 minimum touch targets.
  - VoiceOver/TalkBack labels for all critical elements.
