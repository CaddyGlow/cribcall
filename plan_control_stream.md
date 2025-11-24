# Control Channel + Stream Integration Plan

Goal: ship an end-to-end control channel over the Rust/quiche transport with pinning and pairing enforcement, then use it to drive WebRTC media start/stop. This plan assumes the existing Cargokit plugin and Dart stubs stay in place.

## Phase 1: Baseline QUIC wiring
- Monitor: start `NativeQuicControlServer` when role=monitor and monitoring is enabled; bind to the advertised port (default 48080), supply server identity, and feed trusted listener fingerprints. Ensure mDNS advertises the same port and identity fingerprint.
- Listener: on “Listen”/“View video” selection, resolve target (mDNS or QR payload), create `NativeQuicControlClient` with pinned server fingerprint, and connect to `host:port`.
- Resource lifecycle: keep native handles on a provider/service that survives widget rebuilds, and shut down cleanly when role switches or app goes background/exit.

## Phase 2: Control message loop
- Wrap native `QuicEvent` stream into a Dart control loop that decodes frames and surfaces `ControlMessage` objects to consumers.
- Provide a send queue that serializes `ControlMessage` → frame encoding → native `send(connectionId)`, with backpressure/error propagation.
- Surface connection state (connecting/connected/closed/error) and map native error codes to Dart exceptions with actionable messages (fingerprint mismatch, untrusted client, idle timeout, etc.).

## Phase 3: Trust & pairing enforcement
- Server side: allow only pairing-related messages until a client fingerprint is in the trusted list; reject everything else with a structured error. After trust, accept control/stream commands.
- Client side: feed PIN transcript/HMAC over the control channel; on success, update trusted listeners/monitors repositories and refresh the server allowlist live.
- Denylist/close paths: close the QUIC connection when a client fails pinning or violates framing; ensure native worker tears down per-connection state.

## Phase 4: Presence and heartbeat
- Implement periodic `ping`/`pong` ControlMessages from both sides; drop the connection if pongs are missed. Update UI online/offline based on heartbeat rather than mDNS alone.
- Expose last-seen timestamps per connection and bubble up lightweight status for the listener dashboard cards.

## Phase 5: WebRTC control handoff
- Add handlers to send/receive `webrtcOffer/Answer/Ice` ControlMessages after trust is established.
- Monitor role: create the PeerConnection with host-only ICE, add audio track, and respond to offers with answers; push ICE candidates over control channel.
- Listener role: initiate offer, await answer, add ICE, and surface media to the UI. Support auto-stream settings from monitor (audio/audio+video).

## Phase 6: Native/plugin hardening
- Extend the Rust plugin to emit structured errors for pinning failures/untrusted clients/handshake timeouts; ensure per-connection IDs stay stable.
- Add timeouts for handshake and idle control stream; ensure `cc_quic_conn_close` tears down server/client worker threads.
- Validate buffer sizes and frame limits to protect against oversized frames; log and drop malformed frames.

## Phase 7: UX hooks
- Listener “Listen” button: initiate QUIC connect + ping/pair gate, then auto-open audio stream when permitted; show inline status/errors.
- Monitor control card: show bound port, active connections, and last heartbeat time per listener.
- Error toasts/snackbars for fingerprint mismatch, untrusted client, and pairing failures.

## Phase 8: Testing
- Dart: unit tests for control framing, ping/pong heartbeat logic, trust gate enforcement, and pairing transcript/HMAC over the wire (use fakes for native).
- Native: Rust tests for fingerprint mismatch rejection, allowlist enforcement, and simple loopback handshake with self-signed certs.
- Integration (where feasible): in-process client/server using the plugin on Linux to validate end-to-end message exchange and heartbeat.

## Deliverables
- Working QUIC control channel with pinning/trust gates, heartbeat-driven presence, and ControlMessage send/receive.
- WebRTC offer/answer/ICE relay over control channel with host-only ICE and audio track.
- Dashboard UX updates showing live status and handling errors gracefully.
