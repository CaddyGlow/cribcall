## Progress (SPEC.md Implementation)

### Done so far
- Scaffolded Flutter app with themed UI and role selection for monitor/listener.
- QUIC control models and framing helpers implemented; canonical JSON/HMAC pairing transcript utilities.
- Ed25519 self-signed X.509 generation with cribcall URI SAN; SHA-256 fingerprinting.
- Secure identity storage abstraction (uses secure storage on Android/iOS, file elsewhere) with repository and tests.
- Service identity builder for QR payloads and mDNS advertisements; canonical QR payload strings.
- Monitor dashboard renders pairing QR from canonical payload; listener QR scan flow via mobile_scanner; trusted monitors persisted.
- mDNS platform channel stubs (Android/iOS) and Dart MdnsService abstraction with browse StreamProvider and tests.
- Native mDNS advertise/browse wired on Android (NSD) and iOS (NetService), plus Linux browse via multicast_dns/avahi; Dart provider feeds real lastKnownIp updates.
- RMS-based sound detector core with threshold/min-duration/cooldown and unit tests.
- Trusted monitors repository/controller; basic pinned monitor count surfaced in listener UI.
- Persisted monitor/listener settings to disk with async controllers; trusted monitors capture last known IP from mDNS browse events and allow revocation in state.
- Monitor dashboard now exposes persisted noise thresholds/cooldown, auto-stream selectors, and editable monitor name; listener dashboard includes notification defaults and a “forget monitor” action for pinned entries.
- PIN pairing flow scaffolded with Dart PAKE (X25519/HKDF) for PIN sessions: monitor can start PIN sessions with countdown; listener PIN entry sheet updates trusted monitors on success; pairing state tracks expiry/attempts and HMAC’d transcript keyed off the PAKE key.
- Trusted listeners persist with revoke UI on monitor; listener forget flow now confirms before removal.
- Tests cover control framing/messages, pairing transcripts, identities, service identity, sound detection, and state providers.
- QUIC control transport scaffolded with flutter_quic (client connect + server config) and PKCS#8 export for Ed25519 identities; server accept/pinning still to be wired once the plugin exposes it.

### Remaining to finish SPEC.md
1) **Control channel & QUIC integration**
   - Add native QUIC layer with pinned cert verification, control stream framing, and error codes per spec.
   - Enforce trust list (listener cert fingerprints) and pairing-only message access for untrusted clients.
2) **Pairing flows (QR + PIN)**
   - Finalize PAKE validation (current Dart X25519/HKDF) and PIN pairing transcript/HMAC verification on the control channel.
   - Wire PIN session UX (monitor shows PIN, listener submits) and trust list updates.
3) **WebRTC media path**
   - Integrate Flutter WebRTC plugin; host-only ICE; offer/answer over control channel; audio track from monitor.
   - Auto-stream behavior after NOISE_EVENT with pin-to-keep-live support.
4) **Audio capture + sound detection loop**
   - Hook platform audio capture (AudioRecord/AVAudioEngine/Linux) into SoundDetector; send NOISE_EVENT over QUIC.
5) **Secure key storage**
   - Store private keys in Keystore/Keychain (replace file/secure storage fallback on mobile).
6) **Trusted monitor/listener management**
   - Monitor-side UI to list/revoke trusted listeners; polish listener-side revoke flow and confirm dialogs.
7) **Settings & persistence**
   - Advanced listener defaults (e.g., auto-open rules per monitor) and per-monitor preferences.
8) **Background behavior**
   - Android foreground service; iOS background audio mode; ensure control/alerts continue per spec.
9) **Testing and validation**
    - Integration tests for mTLS pinning, pairing success/failure, QUIC framing errors, WebRTC negotiation, NOISE_EVENT delivery.
    - Platform tests for mDNS advertise/browse, PAKE binding, and secure storage paths.
