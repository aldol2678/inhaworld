// INHA WORLD · 프로필 생성 client (Tier 4 BCD, D-2/D-3/D-4).
// POST /api/world-profile creates the caller's profile; the server owns
// every rule. This module only collects the form values, posts them, and
// parses the documented contract. It never creates a profile on load,
// never invents a nickname, and never sends a title (the server forces
// title to null at creation; editing is a separate, deferred API).
//
// AUTH (Tier 4 guest-open): the v0.1 guest session id in the
// `X-Session-Id` header only — no other credential header is sent. The
// id is read lazily by readGuestSessionId() (fishing-reporter-wiring.js:
// localStorage 'inha-v01:sync-session', fallback
// 'inha-v01:server-session'; null when absent — never fabricated). The
// profile's p_user IS that session id, 1:1 with the session.
//
// Contract (worker.js / create_my_world_profile_v1):
//   POST /api/world-profile { nickname, departmentId, avatarKey }
//   201 { created: true, nickname, departmentId, avatarKey, title: null }
//   200 { created: false, nickname, departmentId, avatarKey, title }
//       — the profile already exists; the submitted values are ignored.
//   400 { error: 'INVALID_NICKNAME' | 'INVALID_DEPARTMENT' |
//                'INVALID_AVATAR' | 'INVALID_TITLE' }
//   409 { error: 'NICKNAME_TAKEN' } — another profile already owns it.
//   409 { error: 'PROFILE_REQUIRED' } — the caller is banned; the server
//       conceals the ban, so this client must not say "banned" either.
//   401 { error: 'SESSION_ID_REQUIRED' } — no guest session id.
//
// Rules mirrored here for instant form feedback only; the server is the
// authority and its refusal always wins:
//   nickname 2–12 chars, [0-9A-Za-z가-힣_ ]+ (space allowed — the RPC
//   mirrors the origin CHECK ^[0-9A-Za-z가-힣_ ]+$), patch35 banned-word filter.
//   departmentId must be an active department (the server checks
//   active=true; the client cannot know the list, so it only checks type).
//   avatarKey one of classic / scholar / explorer / star.

import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";

export const WORLD_PROFILE_API_PATH = "/api/world-profile";

export const WORLD_PROFILE_AVATARS = Object.freeze(["classic", "scholar", "explorer", "star"]);

export const WORLD_PROFILE_ERRORS = Object.freeze({
  INVALID_NICKNAME: "INVALID_NICKNAME",
  INVALID_DEPARTMENT: "INVALID_DEPARTMENT",
  INVALID_AVATAR: "INVALID_AVATAR",
  INVALID_TITLE: "INVALID_TITLE",
  NICKNAME_TAKEN: "NICKNAME_TAKEN",
  PROFILE_REQUIRED: "PROFILE_REQUIRED",
  SESSION_ID_REQUIRED: "SESSION_ID_REQUIRED"
});

const NICKNAME_RE = /^[0-9A-Za-z가-힣_ ]{2,12}$/;

/** Local form check only; the server re-checks everything (incl. the banned-word filter). */
export function isWorldProfileNicknameShape(nickname) {
  return typeof nickname === "string" && NICKNAME_RE.test(nickname);
}

export function isWorldProfileAvatarKey(avatarKey) {
  return WORLD_PROFILE_AVATARS.includes(avatarKey);
}

/** Server response → frozen snapshot, or null when it is not the documented contract. */
export function parseWorldProfile(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.created !== "boolean") return null;
  if (typeof raw.nickname !== "string" || !NICKNAME_RE.test(raw.nickname)) return null;
  if (!Number.isSafeInteger(raw.departmentId) || raw.departmentId <= 0) return null;
  if (!WORLD_PROFILE_AVATARS.includes(raw.avatarKey)) return null;
  if (raw.title !== null && typeof raw.title !== "string") return null;
  return Object.freeze({
    created: raw.created,
    nickname: raw.nickname,
    departmentId: raw.departmentId,
    avatarKey: raw.avatarKey,
    title: raw.title ?? null
  });
}

export class WorldProfileError extends Error {
  constructor(code) {
    super(code);
    this.name = "WorldProfileError";
    this.code = code;
  }
}

/**
 * Create the caller's profile, or return the existing one.
 * @param {object} options
 * @param {function} [options.fetchImpl] fetch (defaults to globalThis.fetch)
 * @param {string} [options.baseUrl] Worker origin (default "")
 * @param {function} [options.getSessionId] defaults to readGuestSessionId()
 * @returns {Promise<{created:boolean,nickname:string,departmentId:number,avatarKey:string,title:string|null}>}
 * @throws {WorldProfileError} with the server refusal code.
 */
export async function createWorldProfile({ nickname, departmentId, avatarKey }, {
  fetchImpl = globalThis.fetch,
  baseUrl = "",
  getSessionId = readGuestSessionId
} = {}) {
  const sessionId = getSessionId?.();
  if (!sessionId) throw new WorldProfileError(WORLD_PROFILE_ERRORS.SESSION_ID_REQUIRED);
  const response = await fetchImpl(`${baseUrl}${WORLD_PROFILE_API_PATH}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Session-Id": sessionId },
    body: JSON.stringify({ nickname, departmentId, avatarKey })
  });
  const body = await response.json().catch(() => null);
  if (response.ok) {
    const parsed = parseWorldProfile(body);
    if (!parsed) throw new WorldProfileError("INVALID_RESPONSE");
    return parsed;
  }
  const code = body?.error;
  if (typeof code === "string" && code in WORLD_PROFILE_ERRORS) throw new WorldProfileError(code);
  throw new WorldProfileError(`HTTP_${response.status}`);
}
