# Firebase guest profile ownership protection (P0 candidate)

This isolated candidate is based on the recovered Cloudflare production Tier 4 Worker, version `92a30405-1dc9-40c6-932c-35ef78802f92` (2026-11-21).
It is **not** an approved production source and has **no automatic Wrangler deployment configuration**.

## Risk being addressed

The production `/api/auth/firebase/login` accepted `guestSessionId` as a profile UUID without requiring proof of possession of that guest session. The legacy `link_firebase_identity_v1` SQL RPC looked up the profile, not the caller's session. A valid Firebase user could therefore attempt to link a profile whose UUID they knew.

## Candidate behavior

1. The client sends `X-Session-Id` only when it has a server-issued guest/device session proof for an existing profile candidate. No proof means normal Firebase login, without automatic profile linking.
2. The Worker checks the bearer session, current epoch and requested profile owner, then calls the new `link_firebase_identity_v2` RPC.
3. The v2 SQL RPC rechecks the same proof, actor, current epoch and profile in one transaction, locking the session and epoch rows before invoking the legacy v1 identity implementation.
4. `/api/auth/firebase/link` supplies its verified session identifier and actor to v2.
5. A failed proof rejects linking. It does not update a Firebase identity or issue a device session.

Missing/invalid proof -> `403 GUEST_SESSION_PROOF_INVALID` (not a guessed profile 404).
Malformed UUID -> HTTP 400.
Ordinary Firebase login without guest candidate is unchanged.
The client should not keep stale profile credentials across account switches; further account-switch QA is required.

## Source of truth and rollout gate

* Original: `aldol2678/inhaworld` PR #7 and prior `aldol2678/inhagame` PR #452, both preserved.
* Migration file: `workers-tier04/migrations/firebase-guest-ownership-v2.sql`. This creates **only** a new RPC, keeping v1 callable during the non-production rollout stage.
* Worker candidate: `workers-tier04/candidates/firebase-guest-ownership/worker.js`; this file **does not** replace `workers-tier04/worker.js` on `main`.
* This candidate is intended for separate review and testing, not merge/deployment.

### Strict sequencing for a later separately authorized release

1. Obtain a dedicated nonproduction Firebase project, test-only Worker and disposable Neon branch.
2. Apply v2 schema on that disposable branch; run real Worker + database session ownership, expiry, guest transfer and auth regression E2E.
3. Verify complete route compatibility, frontend login and logout, client-on-server guest claims, auth errors, and CORS same-host protections.
4. Only after production approval: back up schema, apply v2 first, change Worker to call v2 and verify its version/traffic, then revoke legacy v1 `EXECUTE` from the Worker group using the separate post-cutover SQL. Ensure no other deployed Worker calls v1.
5. Verify backend auth and 401/403 responses. Prepare a coordinated rollback that understands the v1-grant revocation; never undo this protection by replacing a secure Worker with the original vulnerable version.

The proposed post-cutover revoke SQL must **not** execute before all Workers have migrated.

## Verification evidence

* Node 22 mock Worker tests: 11/11 PASS (signature validation with fixture JWKS, missing/wrong/stale proofs, valid guest and ordinary login).
* Client proof helper tests: 5/5 PASS.
* Existing `tier4-firebase-test` Neon branch: rollback-only test validated four rejected proofs, valid owner, plain login and no remaining DB changes; v2 function absent after rollback.
* Updated epoch row locking syntax was separately parsed/executed read-only on the same test branch.
* No Android physical device, actual Firebase Auth account, remote Worker E2E, or production cutover verified.

Do not promote this to release PASS until all blockers are resolved.
