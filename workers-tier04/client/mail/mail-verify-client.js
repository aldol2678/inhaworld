// INHA WORLD · 인하 메일 수동 검증 client (Tier 4 BCD, D-1 fallback (c)).
// The final mail method is (b) code/magic-link sending, but no sending
// service, account or domain auth exists, so the isolation build ships
// the (c) manual-admin fallback only. This module is the *request* half:
// the player submits an inha.edu / inha.ac.kr address, the server records
// a PENDING request, and a human admin later claims it through the
// admin-only Worker endpoint (X-Admin-Key secret; no client for it).
// No real mail is ever sent from here, and no personal data (student ID
// photo, etc.) is collected.
//
// AUTH (Tier 4 guest-open): the v0.1 guest session id in the
// `X-Session-Id` header only — no other credential header is sent. The
// id is read lazily by readGuestSessionId() (fishing-reporter-wiring.js:
// localStorage 'inha-v01:sync-session', fallback
// 'inha-v01:server-session'; null when absent — never fabricated).
//
// Contract (worker.js / request_world_mail_verification_v1):
//   POST /api/world-mail-verify-request { email }
//   201 { requestId, email, status: 'PENDING', duplicate: false }
//   200 { requestId, email, status: 'PENDING', duplicate: true }
//       — the same user+email already has a PENDING request from the last
//       10 minutes; the same request id is returned, nothing new is made.
//   400 { error: 'INVALID_EMAIL' } — not an inha.edu / inha.ac.kr address.
//   429 { error: 'RATE_LIMITED' } — more than 3 requests per user/hour.
//   401 { error: 'SESSION_ID_REQUIRED' } — no guest session id.

import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";

export const WORLD_MAIL_VERIFY_REQUEST_API_PATH = "/api/world-mail-verify-request";

export const WORLD_MAIL_VERIFY_ERRORS = Object.freeze({
  INVALID_EMAIL: "INVALID_EMAIL",
  RATE_LIMITED: "RATE_LIMITED",
  SESSION_ID_REQUIRED: "SESSION_ID_REQUIRED"
});

const INHA_EMAIL_RE = /^[^\s@]+@(inha\.edu|inha\.ac\.kr)$/i;

/** Local form check only; the server re-checks the domain and lowercases the address. */
export function isInhaMailAddress(email) {
  return typeof email === "string" && INHA_EMAIL_RE.test(email.trim());
}

/** Server response → frozen snapshot, or null when it is not the documented contract. */
export function parseWorldMailVerifyRequest(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.requestId !== "string" ||
      typeof raw.email !== "string" || raw.status !== "PENDING" ||
      typeof raw.duplicate !== "boolean") return null;
  if (!isInhaMailAddress(raw.email)) return null;
  return Object.freeze({ requestId: raw.requestId, email: raw.email, status: raw.status, duplicate: raw.duplicate });
}

export class WorldMailVerifyError extends Error {
  constructor(code) {
    super(code);
    this.name = "WorldMailVerifyError";
    this.code = code;
  }
}

/**
 * Submit an inha mail address for manual admin verification.
 * @throws {WorldMailVerifyError} with the server refusal code.
 */
export async function requestWorldMailVerification(email, {
  fetchImpl = globalThis.fetch,
  baseUrl = "",
  getSessionId = readGuestSessionId
} = {}) {
  const sessionId = getSessionId?.();
  if (!sessionId) throw new WorldMailVerifyError(WORLD_MAIL_VERIFY_ERRORS.SESSION_ID_REQUIRED);
  const response = await fetchImpl(`${baseUrl}${WORLD_MAIL_VERIFY_REQUEST_API_PATH}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Session-Id": sessionId },
    body: JSON.stringify({ email: typeof email === "string" ? email.trim() : email })
  });
  const body = await response.json().catch(() => null);
  if (response.ok) {
    const parsed = parseWorldMailVerifyRequest(body);
    if (!parsed) throw new WorldMailVerifyError("INVALID_RESPONSE");
    return parsed;
  }
  const code = body?.error;
  if (typeof code === "string" && code in WORLD_MAIL_VERIFY_ERRORS) throw new WorldMailVerifyError(code);
  throw new WorldMailVerifyError(`HTTP_${response.status}`);
}
