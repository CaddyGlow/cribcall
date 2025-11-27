# Noise Subscription + FCM Fallback Plan

Goal: add local-network HTTP endpoints to subscribe/unsubscribe FCM tokens for noise events so listeners still get alerts when WebSocket drops, while keeping control surfaces local-only and offering a client mute switch.

## Context and constraints
- Noise events already flow over WebSocket when connected; FCM is only for fallback when the connection is lost.
- Endpoints stay on the local control surface (no remote exposure); requests/responses use canonical JSON (RFC 8785) and follow existing pairing/auth rules from SPEC.
- No secrets/certs in repo; subscriptions must bind to the paired identity/fingerprint to prevent token hijack.

## API design (subscribe/unsubscribe)
- `POST /noise/subscribe`: body includes `fcmToken`, `platform`, optional `leaseSeconds`; server derives `pairingId/deviceId` from the authenticated/pinned identity and rejects if a body-provided value is present and mismatched. Response returns `subscriptionId` (stable per token+device), `expiresAt`, and `acceptedLeaseSeconds`. Idempotent on same token/device.
- `POST /noise/unsubscribe`: body includes `fcmToken` (or `subscriptionId`); server derives `pairingId/deviceId` from the authenticated/pinned identity and rejects mismatches. Idempotent even if not found. Returns remaining active lease info if present.
- Errors: structured codes for unauthenticated/unpaired, stale token, invalid JSON, lease too long, and clock skew (if relevant). Reject unknown fields per SPEC style.

## Lease semantics and lifecycle
- Server stores a per-device lease with `expiresAt` tied to exactly one active token; default lease (e.g., 24h) if client omits. Hard cap lease to prevent indefinite sends.
- Client renews when within a renewal window (e.g., 25–50% of lease left) or on app start/resume. If client cannot reach server, lease expires naturally and FCM sends stop.
- Token rotation: newest subscribe overwrites the prior token for that device/pairing; optionally keep the old token for a brief grace window (configurable, short) but never deliver to both.
- Unpairing clears all leases for that pairing on the server; client also attempts unsubscribe when online.

## Server behavior
- Persist subscription by deriving pairing/device from the pinned/authenticated fingerprint (ignore spoofed body values) and deny if the client is not trusted. Store platform for analytics and platform-specific payload tuning.
- Delivery: prefer live WebSocket; send FCM only when WebSocket is absent or recently disconnected. Include dedupe key per event and per-subscription TTL to avoid repeats. When a new token arrives for a device, mark it active and stop sending to the superseded token after any configured grace window.
- Cleanup: drop leases on expiry and after repeated send failures (`NotRegistered`, `InvalidRegistration`, `MismatchSenderId` etc.). Log structured events for subscribe/unsubscribe/send attempts.

## Client behavior
- Track per-paired-device state: `{deviceId/pairingId, fcmTokenUsed, status (subscribed|pending|unsubscribed), expiresAt/leaseSeconds, lastAttemptError}` persisted locally.
- On app start/resume or `onTokenRefresh`: if token changed or lease nearing expiry, enqueue subscribe and set status `pending`; update to `subscribed` on success with returned `expiresAt`.
- On unpair/sign-out: clear local state and enqueue unsubscribe (best-effort) when reachable; if offline, rely on lease expiry.
- Retry subscribe/unsubscribe with backoff on network/auth errors; refresh token and resubscribe on 401/invalid-token responses.
- FCM handling: deliver noise notification payloads unless muted (see below); ensure background handling surfaces alerts appropriately per platform.

## Mute switch (client-side only)
- Per-device mute flag stored locally; when enabled, suppress presenting noise notifications while leaving the lease active. Toggle is independent of subscription state.
- Consider surfacing mute status in UI and persisting across restarts; unmute resumes showing incoming FCM notifications immediately.

## Testing and validation
- Backend: unit/integration tests for subscribe/unsubscribe auth gates, idempotency, lease acceptance/rejection, expiry cleanup, and fallback send when WebSocket is down; cover canonical JSON and unknown-field rejection.
- Client (Flutter): tests for token refresh/resubscribe flow, lease renewal timing, pending queue with offline retry, mute toggle behavior, and unsubscribe on unpair.
- End-to-end (where possible): simulate WebSocket loss and verify NOISE_EVENT delivers over FCM once per event; verify muted clients drop the notification locally.

## Deliverables
- SPEC/API docs updated with endpoints, schemas, lease rules, and mute behavior; changelog entry for the task.
- Server routes/handlers with persistence, fallback send logic, and observability.
- Client subscription manager with token lifecycle handling, mute switch UI/storage, and tests aligned to the above cases.
