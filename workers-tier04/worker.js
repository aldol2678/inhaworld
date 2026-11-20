// INHA WORLD — Tier 4 (A-3 state machines; superset of A-1 + A-2) data-layer Cloudflare Worker (isolated test).
// Port of (aldol2678/inhagame HEAD 0b72d259):
//   A-1 reads (see the A-1 worker): GET /api/world-inventory, /api/world-wallet,
//     /api/world-progression, /api/world-loadout, /api/world-shop,
//     /api/world-shop-capabilities, /api/world-staff-badges, /api/world-profile
//   A-2 writes:
//     apps/world/src/appearance/loadout-client.js      -> POST /api/world-loadout
//       (equip_my_world_item_v1 / unequip_my_world_item_v1)
//     apps/world/src/shop/shop-client.js               -> POST /api/world-shop-purchase
//       (purchase_world_shop_listing_v1 / v2; v2 when the body carries shopId)
//     apps/world/src/attendance/attendance-client.js   -> POST /api/world-attendance-claim
//       + GET /api/world-attendance (claim/get_my_world_attendance_v1)
//     apps/world/src/guestbook/guestbook-client.js     -> POST /api/world-guestbook
//       + GET /api/world-guestbook (create/update/delete/get_world_guestbook_entry_v2)
//     apps/world/src/jeongseok/access-client.js        -> POST /api/world-jeongseok-pass
//       + GET /api/world-jeongseok-access (purchase_jeongseok_pass_v1 / get_jeongseok_access_v1)
//     apps/world/src/rooms/cooking-client.js           -> POST /api/world-cooking
//       (cook_my_world_recipe_v1)
//     apps/world/src/rooms/furniture-client.js         -> POST /api/world-room-furniture
//       + GET /api/world-room-furniture (save/get_world_room_furniture_v1)
//     apps/world/src/rooms/personal-room-client.js     -> POST /api/world-personal-room
//       + GET /api/world-personal-room (get_or_create/set_my_personal_room_visibility_v1)
//     apps/world/src/rooms/room-knock.js               -> POST /api/world-room-knock
//       (knock/get/list/respond_room_knock_v1; POLLING only — no push. The owner
//       heartbeat is list (12 s presence), the visitor polls get every 1.5 s for
//       up to 32 s; a PENDING knock expires after 30 s server-side. Push is C-group.)
// A-3 state machines:
//   src/daily-quiz/daily-quiz-client.js                 -> GET /api/world-daily-quiz
//     + POST /api/world-daily-quiz-start + POST /api/world-daily-quiz-answer
//     (get/start/answer_my_world_daily_quiz_v1)
//   src/life-skills/life-skill-book-client.js           -> GET /api/world-life-skills
//     + GET /api/world-life-skill-tree + POST /api/world-life-node-unlock
//     + POST /api/world-life-tree-reset
//     (get_my_world_life_skills_v1 / get_my_world_life_skill_tree_v1 /
//      unlock_my_world_life_node_v1 / reset_my_world_life_tree_v1)
//   src/social/social-client.js                         -> GET /api/world-social
//     + GET /api/world-public-profile + GET /api/world-relationship
//     + POST /api/world-friend-request + POST /api/world-report-user
//     + POST /api/world-block-user
//     (get_my_world_social / get_world_public_profile / get_world_relationship /
//      send/respond/cancel_world_friend_request / remove_world_friend /
//      report_world_user / block/unblock_world_user)
//   src/social/accompany-client.js                      -> GET /api/world-accompany
//     + POST /api/world-accompany (get/propose/respond/end_world_accompany)
//   src/biryong/biryong-cloud-sync.js                   -> GET /api/world-biryong-progress
//     + POST /api/world-biryong-progress
//     (get/merge_my_biryong_progress_v1)
//   src/biryong/biryong-village-relationship-client.js  -> GET /api/world-biryong-npc-relationship(s)
//     + POST /api/world-biryong-npc-advance
//     (get_my_biryong_npc_relationship(s)_v1 /
//      world_biryong_npc_relationship_advance_v1)
//   (campus NPC relationships: no dedicated client file in the snapshot;
//    same shape as biryong) -> GET /api/world-campus-npc-relationship(s)
//     + POST /api/world-campus-npc-apply
//     (get_my_world_campus_npc_relationship(s)_v1 /
//      world_campus_npc_relationship_apply_v1)
//   src/events/zombie-university-2026/event-client.js   -> GET /api/world-mcm-event
//     + POST /api/world-mcm-landlord-run + POST /api/world-mcm-landlord-choice
//     + POST /api/world-mcm-claim
//     (get_my_mcm_2026_event_v1 / start/submit_mcm_landlord_run_v1 /
//      claim_my_mcm_2026_main_reward_v1 /
//      claim_my_mcm_landlord_first_clear_reward_v1)
//   advance_mcm_2026_event_v1 has NO HTTP endpoint: it is server-only in the
//   original (service_role JWT) and no client calls it; the Worker is the
//   server caller and the RPC is exercised by the oracle/parity directly.
// from Vercel / Supabase Edge Functions + Supabase to the Workers Fetch API + Neon.
// Status codes, guard order, error bodies and headers follow the originals; the
// RPCs live in schema.sql.
//
// Identity (decision A, 2026-11-12): the caller is a v0.1 guest session. The
// server-issued session id arrives in `X-Session-Id` and must exist in
// public.sessions. It replaces the Supabase access token (`Authorization: Bearer`)
// everywhere. The RPCs take the session id as `p_user uuid` (their first parameter).
//
// Guest-open defaults (A-2, reversible by an Aldol decision — see README.md):
// self-only writes (loadout, purchase, attendance, jeongseok pass, cooking,
// furniture, personal room) need only a session. Writes visible to others
// (guestbook create/update/delete, room knock knock/get/list/respond) additionally
// need a profile: a missing or banned profile is 409 PROFILE_REQUIRED (rank rule).
// Guestbook READ also requires a profile — the original get_world_guestbook_v2
// enforces it through world_social_caller, so a profile-less session gets 409
// there too. There is no ban check on the guest-open paths (Tier 3 decision).
//
// DATABASE_URL comes from `wrangler secret put DATABASE_URL` only — never from a
// file, [vars], or a log line.
//
// Error mapping (RPC exception message -> HTTP status / body):
//   PERMANENT_ACCOUNT_REQUIRED -> 401  (null actor; unreachable after verifySession)
//   ACCOUNT_UNAVAILABLE        -> 403  (session row exists but the account check fails)
//   PROFILE_NOT_FOUND          -> 409  { error: 'PROFILE_REQUIRED' } (rank rule)
//   SOCIAL_RESTRICTED          -> 403
//   LAYOUT_DENIED / ROOM_PRIVATE / VISIT_DECLINED / KNOCK_REQUIRED / NOT_FRIENDS
//                              -> 403
//   SHOP_NOT_FOUND / ROOM_NOT_FOUND / KNOCK_NOT_FOUND -> 404
//   INVALID_* / INVALID_CONTENT / INVALID_LOCATION / INVALID_VISIBILITY /
//     INVALID_PASS_TYPE / INVALID_RECIPE_REQUEST / INVALID_RESPONSE
//                              -> 400  (errcode 22023 in the original)
//   TARGET_UNAVAILABLE / ENTRY_UNAVAILABLE -> 400 (errcode 22023 in the original)
//   IDEMPOTENCY_CONFLICT       -> 409
//   LAYOUT_CONFLICT            -> 409  (errcode 40001 in the original)
//   business refusals (P0001 in the original: INSUFFICIENT_FUNDS, LEVEL_REQUIRED,
//     PURCHASE_LIMIT_REACHED, ITEM_ALREADY_OWNED, ITEM_NOT_OWNED, ITEM_UNAVAILABLE,
//     ITEM_NOT_EQUIPPABLE, SLOT_MISMATCH, SHOP_INACTIVE, LISTING_*,
//     SHOP_LISTING_MISMATCH, INVALID_LISTING, PASS_ALREADY_ACTIVE,
//     FREE_ACCESS_ELIGIBLE, PASS_UNAVAILABLE, JEONGSEOK_GATE_UNAVAILABLE,
//     RECIPE_UNAVAILABLE, DAILY_LIMIT_REACHED, GUESTBOOK_COOLDOWN) -> 409
//     (UNKNOWN_ITEM is 22023 -> 400)
//   COOKING_STATION_REQUIRED   -> 403  (errcode 42501 in the original)
//   RATE_LIMITED               -> 429
//   ATTENDANCE_REWARD_FAILED / PURCHASE_GRANT_FAILED / PURCHASE_READBACK_FAILED /
//     PURCHASE_STATE_CONFLICT  -> 503  (server could not complete the write)
//   anything else              -> 503  { error: <endpoint>_UNAVAILABLE }
import { neon } from '@neondatabase/serverless';

// One HTTP query per call, each with its own upstream timeout.
function connect(env, timeoutMs) {
  return neon(env.DATABASE_URL, {
    fetchOptions: { signal: AbortSignal.timeout(timeoutMs) },
  });
}

// "The database answered with an error" (a raised exception, a failed cast) as
// opposed to "the database could not be reached" (no connection string, network
// failure, timeout, unreadable reply). The originals make the same split between
// a non-2xx PostgREST reply and a failed fetch.
const isDbAnswer = (error) => error?.name === 'NeonDbError' && !error.sourceError;

const json = (status, body, headers) => {
  const out = new Headers(headers);
  if (!out.has('Content-Type')) out.set('Content-Type', 'application/json; charset=utf-8');
  return new Response(JSON.stringify(body), { status, headers: out });
};

// ---- session verification (replaces verifyNpcAiUser / auth.getUser) ----
// crypto.randomUUID() ids: UUID-shaped TEXT. Returns the session id (lower case)
// when the row exists, null when the header is missing / malformed / unknown.
// Throws when the lookup itself fails.
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const IDEMPOTENCY_KEY = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$/;

async function verifySession(request, env) {
  const header = request.headers.get('x-session-id') ?? '';
  if (!SESSION_ID.test(header)) return null;
  const id = header.toLowerCase();
  const sql = connect(env, 5000);
  const rows = await sql`select id from public.sessions where id = ${id} limit 1`;
  return rows.length === 1 && rows[0]?.id === id ? id : null;
}

// Profile gate for writes visible to others (guestbook, room knock): the
// profiles row must exist and not be banned. Returns true when it passes.
async function hasProfile(env, actor) {
  const sql = connect(env, 5000);
  const rows = await sql`select user_id, is_banned from public.profiles where user_id = ${actor}::uuid limit 1`;
  return rows.length === 1 && rows[0]?.is_banned === false;
}

function sameHostOrigin(request) {
  const origin = request.headers.get('origin');
  if (!origin) return true;
  try {
    return new URL(origin).host === request.headers.get('host');
  } catch {
    return false;
  }
}

class Tier4Error extends Error {
  constructor(message, status = 503) {
    super(message);
    this.status = status;
  }
}

// RPC exception message -> [HTTP status, body error code]. PROFILE_NOT_FOUND is
// renamed to PROFILE_REQUIRED in the body (the rank rule's public name).
const RPC_ERRORS = new Map([
  ['PERMANENT_ACCOUNT_REQUIRED', [401, 'PERMANENT_ACCOUNT_REQUIRED']],
  ['ACCOUNT_UNAVAILABLE', [403, 'ACCOUNT_UNAVAILABLE']],
  ['PROFILE_NOT_FOUND', [409, 'PROFILE_REQUIRED']],
  ['SOCIAL_RESTRICTED', [403, 'SOCIAL_RESTRICTED']],
  ['LAYOUT_DENIED', [403, 'LAYOUT_DENIED']],
  ['ROOM_PRIVATE', [403, 'ROOM_PRIVATE']],
  ['VISIT_DECLINED', [403, 'VISIT_DECLINED']],
  ['KNOCK_REQUIRED', [403, 'KNOCK_REQUIRED']],
  ['NOT_FRIENDS', [403, 'NOT_FRIENDS']],
  ['COOKING_STATION_REQUIRED', [403, 'COOKING_STATION_REQUIRED']],
  ['SHOP_NOT_FOUND', [404, 'SHOP_NOT_FOUND']],
  ['ROOM_NOT_FOUND', [404, 'ROOM_NOT_FOUND']],
  ['KNOCK_NOT_FOUND', [404, 'KNOCK_NOT_FOUND']],
  ['INVALID_IDEMPOTENCY_KEY', [400, 'INVALID_IDEMPOTENCY_KEY']],
  ['INVALID_APPEARANCE_SLOT', [400, 'INVALID_APPEARANCE_SLOT']],
  ['INVALID_ITEM_ID', [400, 'INVALID_ITEM_ID']],
  ['UNKNOWN_ITEM', [400, 'UNKNOWN_ITEM']],
  ['INVALID_LISTING', [409, 'INVALID_LISTING']],
  ['INVALID_LOCATION', [400, 'INVALID_LOCATION']],
  ['INVALID_CONTENT', [400, 'INVALID_CONTENT']],
  ['INVALID_VISIBILITY', [400, 'INVALID_VISIBILITY']],
  ['INVALID_PASS_TYPE', [400, 'INVALID_PASS_TYPE']],
  ['INVALID_RECIPE_REQUEST', [400, 'INVALID_RECIPE_REQUEST']],
  ['INVALID_RESPONSE', [400, 'INVALID_RESPONSE']],
  ['INVALID_LAYOUT', [400, 'INVALID_LAYOUT']],
  ['TARGET_UNAVAILABLE', [400, 'TARGET_UNAVAILABLE']],
  ['ENTRY_UNAVAILABLE', [400, 'ENTRY_UNAVAILABLE']],
  ['IDEMPOTENCY_CONFLICT', [409, 'IDEMPOTENCY_CONFLICT']],
  // BCD fix (2026-11-20, found before first deploy, corrected after the
  // seed-gate re-run): the inventory mutation helper raises two P0001
  // business refusals a COOK can hit — INPUT_UNAVAILABLE when the input
  // item is missing from the catalog or DISABLED/HIDDEN, and
  // INSUFFICIENT_QUANTITY when the caller holds fewer than the recipe
  // needs. Without these entries mapRpcError fell through to the 503
  // COOKING_UNAVAILABLE fallback, misreporting a normal "not enough
  // ingredients" refusal as a server failure.
  ['INPUT_UNAVAILABLE', [409, 'INPUT_UNAVAILABLE']],
  ['INSUFFICIENT_QUANTITY', [409, 'INSUFFICIENT_QUANTITY']],
  ['LAYOUT_CONFLICT', [409, 'LAYOUT_CONFLICT']],
  ['SHOP_API_UNAVAILABLE', [503, 'SHOP_API_UNAVAILABLE']],
  ['INSUFFICIENT_FUNDS', [409, 'INSUFFICIENT_FUNDS']],
  ['LEVEL_REQUIRED', [409, 'LEVEL_REQUIRED']],
  ['PURCHASE_LIMIT_REACHED', [409, 'PURCHASE_LIMIT_REACHED']],
  ['ITEM_ALREADY_OWNED', [409, 'ITEM_ALREADY_OWNED']],
  ['ITEM_NOT_OWNED', [409, 'ITEM_NOT_OWNED']],
  ['ITEM_UNAVAILABLE', [409, 'ITEM_UNAVAILABLE']],
  ['ITEM_NOT_EQUIPPABLE', [409, 'ITEM_NOT_EQUIPPABLE']],
  ['SLOT_MISMATCH', [409, 'SLOT_MISMATCH']],
  ['SHOP_INACTIVE', [409, 'SHOP_INACTIVE']],
  ['SHOP_LISTING_MISMATCH', [409, 'SHOP_LISTING_MISMATCH']],
  ['LISTING_INACTIVE', [409, 'LISTING_INACTIVE']],
  ['LISTING_LOCKED', [409, 'LISTING_LOCKED']],
  ['LISTING_NOT_STARTED', [409, 'LISTING_NOT_STARTED']],
  ['LISTING_EXPIRED', [409, 'LISTING_EXPIRED']],
  ['PASS_ALREADY_ACTIVE', [409, 'PASS_ALREADY_ACTIVE']],
  ['FREE_ACCESS_ELIGIBLE', [409, 'FREE_ACCESS_ELIGIBLE']],
  ['PASS_UNAVAILABLE', [409, 'PASS_UNAVAILABLE']],
  ['JEONGSEOK_GATE_UNAVAILABLE', [409, 'JEONGSEOK_GATE_UNAVAILABLE']],
  ['RECIPE_UNAVAILABLE', [409, 'RECIPE_UNAVAILABLE']],
  ['DAILY_LIMIT_REACHED', [409, 'DAILY_LIMIT_REACHED']],
  ['GUESTBOOK_COOLDOWN', [409, 'GUESTBOOK_COOLDOWN']],
  ['RATE_LIMITED', [429, 'RATE_LIMITED']],
  ['ATTENDANCE_REWARD_FAILED', [503, 'ATTENDANCE_REWARD_FAILED']],
  ['PURCHASE_GRANT_FAILED', [503, 'PURCHASE_GRANT_FAILED']],
  ['PURCHASE_READBACK_FAILED', [503, 'PURCHASE_READBACK_FAILED']],
  ['PURCHASE_STATE_CONFLICT', [503, 'PURCHASE_STATE_CONFLICT']],
  // ---- A-3 state machines (errcode -> status follows the A-2 convention:
  // 22023 -> 400, P0001 business refusal -> 409, P0002 not-found -> 404,
  // 42501 denial -> 403, SIGN_IN_REQUIRED -> 401, 23505 conflict -> 409) ----
  ['SIGN_IN_REQUIRED', [401, 'SIGN_IN_REQUIRED']],
  ['SERVER_ONLY', [403, 'SERVER_ONLY']],
  ['NOT_ALLOWED', [403, 'NOT_ALLOWED']],
  ['INVALID_ANSWER', [400, 'INVALID_ANSWER']],
  ['INVALID_REQUEST_ID', [400, 'INVALID_REQUEST_ID']],
  ['INVALID_LIFE_NODE_ID', [400, 'INVALID_LIFE_NODE_ID']],
  ['INVALID_LIFE_SKILL_ID', [400, 'INVALID_LIFE_SKILL_ID']],
  ['INVALID_RELATIONSHIP_STAGE', [400, 'INVALID_RELATIONSHIP_STAGE']],
  ['INVALID_RELATIONSHIP_SOURCE', [400, 'INVALID_RELATIONSHIP_SOURCE']],
  ['INVALID_RELATIONSHIP_SOURCE_REF', [400, 'INVALID_RELATIONSHIP_SOURCE_REF']],
  ['INVALID_RELATIONSHIP_RESULT_REF', [400, 'INVALID_RELATIONSHIP_RESULT_REF']],
  ['RELATIONSHIP_RESULT_REF_REQUIRED', [400, 'RELATIONSHIP_RESULT_REF_REQUIRED']],
  ['INVALID_RELATIONSHIP_DELTA', [400, 'INVALID_RELATIONSHIP_DELTA']],
  ['INVALID_RELATIONSHIP_OCCURRENCE', [400, 'INVALID_RELATIONSHIP_OCCURRENCE']],
  ['INVALID_RELATIONSHIP_SIGNAL', [400, 'INVALID_RELATIONSHIP_SIGNAL']],
  ['RELATIONSHIP_DEFINITION_VERSION_MISMATCH', [400, 'RELATIONSHIP_DEFINITION_VERSION_MISMATCH']],
  ['RELATIONSHIP_DELTA_SIGN_MISMATCH', [400, 'RELATIONSHIP_DELTA_SIGN_MISMATCH']],
  ['INVALID_CAMPUS_NPC_RELATIONSHIP_EVENT', [400, 'INVALID_CAMPUS_NPC_RELATIONSHIP_EVENT']],
  ['INVALID_FIRST_MEETING_OCCURRENCE', [400, 'INVALID_FIRST_MEETING_OCCURRENCE']],
  ['INVALID_CLAIM_TYPE', [400, 'INVALID_CLAIM_TYPE']],
  ['INVALID_ACTOR', [400, 'INVALID_ACTOR']],
  ['INVALID_BIRYONG_PROGRESS', [400, 'INVALID_BIRYONG_PROGRESS']],
  ['INVALID_BIRYONG_STEP', [400, 'INVALID_BIRYONG_STEP']],
  ['INVALID_BIRYONG_SHOUTS', [400, 'INVALID_BIRYONG_SHOUTS']],
  ['INVALID_BIRYONG_LORE', [400, 'INVALID_BIRYONG_LORE']],
  ['INVALID_DESTINATION', [400, 'INVALID_DESTINATION']],
  ['INVALID_CATEGORY', [400, 'INVALID_CATEGORY']],
  ['INVALID_PLACE_ZONE', [400, 'INVALID_PLACE_ZONE']],
  ['CANNOT_REPORT_SELF', [400, 'CANNOT_REPORT_SELF']],
  ['INVALID_ARGUMENT', [400, 'INVALID_ARGUMENT']],
  ['INVALID_EVENT_ACTION', [400, 'INVALID_EVENT_ACTION']],
  ['LIFE_NODE_NOT_FOUND', [404, 'LIFE_NODE_NOT_FOUND']],
  ['LIFE_SKILL_NOT_FOUND', [404, 'LIFE_SKILL_NOT_FOUND']],
  ['BIRYONG_NPC_NOT_AVAILABLE', [404, 'BIRYONG_NPC_NOT_AVAILABLE']],
  ['CAMPUS_NPC_NOT_AVAILABLE', [404, 'CAMPUS_NPC_NOT_AVAILABLE']],
  ['RUN_NOT_FOUND', [404, 'RUN_NOT_FOUND']],
  ['QUIZ_RUN_NOT_FOUND', [404, 'QUIZ_RUN_NOT_FOUND']],
  ['QUIZ_UNAVAILABLE', [409, 'QUIZ_UNAVAILABLE']],
  ['QUIZ_RUN_EXPIRED', [409, 'QUIZ_RUN_EXPIRED']],
  ['QUIZ_ALREADY_ANSWERED', [409, 'QUIZ_ALREADY_ANSWERED']],
  ['QUIZ_QUESTION_MISMATCH', [409, 'QUIZ_QUESTION_MISMATCH']],
  ['LIFE_NODE_MAX_RANK', [409, 'LIFE_NODE_MAX_RANK']],
  ['LIFE_NODE_PREREQUISITE_LOCKED', [409, 'LIFE_NODE_PREREQUISITE_LOCKED']],
  ['LIFE_SP_INSUFFICIENT', [409, 'LIFE_SP_INSUFFICIENT']],
  ['LIFE_LEVEL_REQUIRED', [409, 'LIFE_LEVEL_REQUIRED']],
  ['LIFE_SKILL_LEVEL_REQUIRED', [409, 'LIFE_SKILL_LEVEL_REQUIRED']],
  ['LIFE_NODE_INACTIVE', [409, 'LIFE_NODE_INACTIVE']],
  ['LIFE_SKILL_INACTIVE', [409, 'LIFE_SKILL_INACTIVE']],
  ['LIFE_TREE_RESET_COOLDOWN', [409, 'LIFE_TREE_RESET_COOLDOWN']],
  ['LIFE_TREE_RESET_EMPTY', [409, 'LIFE_TREE_RESET_EMPTY']],
  ['LIFE_SP_LEDGER_INVALID', [409, 'LIFE_SP_LEDGER_INVALID']],
  ['LIFE_PROGRESSION_CURVE_INVALID', [409, 'LIFE_PROGRESSION_CURVE_INVALID']],
  ['RELATIONSHIP_STAGE_STEP_REQUIRED', [409, 'RELATIONSHIP_STAGE_STEP_REQUIRED']],
  ['CLAIM_NOT_ELIGIBLE', [409, 'CLAIM_NOT_ELIGIBLE']],
  ['EVENT_NOT_ACTIVE', [409, 'EVENT_NOT_ACTIVE']],
  ['ALREADY_BUSY', [409, 'ALREADY_BUSY']],
  ['QUIZ_REWARD_FAILED', [503, 'QUIZ_REWARD_FAILED']],
  // ---- BCD (profile / mail fallback / online polling) ----
  ['INVALID_NICKNAME', [400, 'INVALID_NICKNAME']],
  ['INVALID_DEPARTMENT', [400, 'INVALID_DEPARTMENT']],
  ['INVALID_AVATAR', [400, 'INVALID_AVATAR']],
  ['INVALID_TITLE', [400, 'INVALID_TITLE']],
  ['NICKNAME_TAKEN', [409, 'NICKNAME_TAKEN']],
  ['INVALID_EMAIL', [400, 'INVALID_EMAIL']],
  ['MAIL_REQUEST_NOT_FOUND', [404, 'MAIL_REQUEST_NOT_FOUND']],
  ['SESSION_ID_REQUIRED', [400, 'SESSION_ID_REQUIRED']],
  ['INVALID_SPACE', [400, 'INVALID_SPACE']],
  // Append-only / projection guards (never expected from a normal API call).
  ['BIRYONG_RELATIONSHIP_EVENT_APPEND_ONLY', [409, 'BIRYONG_RELATIONSHIP_EVENT_APPEND_ONLY']],
  ['CAMPUS_NPC_RELATIONSHIP_EVENT_APPEND_ONLY', [409, 'CAMPUS_NPC_RELATIONSHIP_EVENT_APPEND_ONLY']],
  ['BIRYONG_RELATIONSHIP_PROJECTION_IMMUTABLE', [409, 'BIRYONG_RELATIONSHIP_PROJECTION_IMMUTABLE']],
  ['BIRYONG_RELATIONSHIP_PROJECTION_INVALID', [409, 'BIRYONG_RELATIONSHIP_PROJECTION_INVALID']],
  ['CAMPUS_NPC_RELATIONSHIP_PROJECTION_IMMUTABLE', [409, 'CAMPUS_NPC_RELATIONSHIP_PROJECTION_IMMUTABLE']],
  ['CAMPUS_NPC_RELATIONSHIP_PROJECTION_INVALID', [409, 'CAMPUS_NPC_RELATIONSHIP_PROJECTION_INVALID']],
  ['LIFE_SP_APPEND_ONLY', [409, 'LIFE_SP_APPEND_ONLY']],
  ['LIFE_NODE_APPEND_ONLY', [409, 'LIFE_NODE_APPEND_ONLY']],
  ['LIFE_TREE_RESET_APPEND_ONLY', [409, 'LIFE_TREE_RESET_APPEND_ONLY']],
  ['LIFE_TREE_DEFINITION_IMMUTABLE', [409, 'LIFE_TREE_DEFINITION_IMMUTABLE']],
  ['CLAIM_FINAL', [409, 'CLAIM_FINAL']],
]);

function mapRpcError(error, fallbackCode) {
  // A Tier4Error raised by the Worker's own validation (bad() etc.) is
  // already an HTTP error — never remap it to the 503 fallback.
  if (error instanceof Tier4Error) return error;
  if (isDbAnswer(error)) {
    const hit = RPC_ERRORS.get(error.message);
    if (hit) return new Tier4Error(hit[1], hit[0]);
  }
  return new Tier4Error(fallbackCode, 503);
}

function replyError(error, fallbackCode, headers) {
  const known = error instanceof Tier4Error;
  return json(known ? error.status : 503,
    { error: known ? error.message : fallbackCode }, headers);
}

async function requireSession(request, env, fallbackCode) {
  let actor;
  try {
    actor = await verifySession(request, env);
  } catch {
    throw new Tier4Error(fallbackCode, 503);
  }
  if (typeof actor !== 'string') throw new Tier4Error('AUTH_REQUIRED', 401);
  return actor;
}

async function requireProfile(request, env, actor, fallbackCode) {
  let ok;
  try {
    ok = await hasProfile(env, actor);
  } catch {
    throw new Tier4Error(fallbackCode, 503);
  }
  if (!ok) throw new Tier4Error('PROFILE_REQUIRED', 409);
}

function baseHeaders() {
  return new Headers({ 'Cache-Control': 'private, no-store', Vary: 'X-Session-Id' });
}

async function readJsonBody(request) {
  const text = await request.text();
  if (text === '') return null;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

// Guard order mirrors Tier 3 / A-1: method 405 -> same-host Origin 403 ->
// session 401 -> body shape 400 -> RPC errors mapped.
async function guard(request, headers, method) {
  if (request.method !== method) {
    headers.set('Allow', method);
    return new Response(null, { status: 405, headers });
  }
  if (!sameHostOrigin(request)) return new Response(null, { status: 403, headers });
  return null;
}

async function guardGet(request, headers) {
  if (request.method !== 'GET') {
    headers.set('Allow', 'GET');
    return new Response(null, { status: 405, headers });
  }
  if ((await request.text()) !== '') return new Response(null, { status: 400, headers });
  if (!sameHostOrigin(request)) return new Response(null, { status: 403, headers });
  return null;
}

// One RPC returning a single jsonb value in `result` (A-1 GET pattern).
function plainHandler(rpcCall, fallbackCode) {
  return async function handle(request, env) {
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await rpcCall(sql, actor);
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  };
}

// One RPC returning a single jsonb value in `result`, with the profile gate
// (social/accompany GETs: the original RPCs enforce it through
// world_social_caller, so a profile-less session gets 409 either way).
function plainHandlerProfile(rpcCall, fallbackCode) {
  return async function handle(request, env) {
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const actor = await requireSession(request, env, fallbackCode);
      await requireProfile(request, env, actor, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await rpcCall(sql, actor);
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  };
}

// POST handler: guard -> session -> (optional profile) -> JSON body -> RPC.
function postHandler(fallbackCode, run, { profileRequired = false } = {}) {
  return async function handle(request, env) {
    const headers = baseHeaders();
    const blocked = await guard(request, headers, 'POST');
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const actor = await requireSession(request, env, fallbackCode);
      if (profileRequired) await requireProfile(request, env, actor, fallbackCode);
      const body = await readJsonBody(request);
      if (body === undefined || body === null || typeof body !== 'object' || Array.isArray(body)) {
        return new Response(null, { status: 400, headers });
      }
      const sql = connect(env, 10000);
      try {
        const result = await run(sql, actor, body);
        return json(200, result, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  };
}

const bad = () => new Tier4Error('INVALID', 400);
const isUuid = (v) => typeof v === 'string' && SESSION_ID.test(v);
const isKey = (v) => typeof v === 'string' && IDEMPOTENCY_KEY.test(v);

// ---- BCD: nickname banned-word filter (word-alchemy patch35, verbatim) ----
// Source: ~/workspace/deploy/word-alchemy/index.html:8975-8994
// BATTLE_NICK_BANNED + btNormalizeNickForFilter + btNickHasBanned, copied
// exactly so the Worker check and the patch35 client check agree. The RPC
// re-checks in SQL (defence-in-depth); the Worker check runs first so the
// NFKC/leetspeak normalisation is exact here.
const BATTLE_NICK_BANNED = [
  '씨발', '시발', '시바', '씨바', '썅', '병신', '지랄', '개새끼', '개새', '개년',
  '새끼', '좆', '좃', '씹', '자지', '보지', '엿', '닥쳐', '꺼져', '죽어', '뒤져',
  '미친년', '미친놈', 'ㅅㅂ', 'ㅆㅂ', 'ㅂㅅ', 'ㅈㄹ',
  '섹스', '야동', '포르노', '자위', '음란',
  '쪽바리', '짱깨', '김치녀', '된장녀', '한남충',
  'fuck', 'shit', 'bitch', 'cunt', 'dick', 'pussy', 'whore', 'slut', 'bastard', 'asshole',
];
function btNormalizeNickForFilter(s) {
  let v = String(s || '').normalize('NFKC').toLowerCase();
  v = v.replace(/1/g, 'i').replace(/0/g, 'o').replace(/@/g, 'a').replace(/\$/g, 's');
  v = v.replace(/[\s\-_.,~^*!?·•…]+/g, '');
  v = v.replace(/(.)\1+/g, '$1');
  return v;
}
function btNickHasBanned(nick) {
  const v = btNormalizeNickForFilter(nick);
  if (!v) return false;
  return BATTLE_NICK_BANNED.some((w) => v.includes(w));
}

// ---- BCD: online-count 5-second cache (C-2) ----
// Worker-local memory cache: with N instances the count query runs at most
// N/5 per second instead of N/20 per client poll. asOf is the cache time.
let onlineCountCache = { at: 0, body: null };

async function rpcResult(queryPromise) {
  const rows = await queryPromise;
  return rows[0]?.result ?? null;
}

const loadoutGet = plainHandler(
  (sql, actor) => sql`select public.get_my_world_appearance_loadout_v1(${actor}::uuid) as result`,
  'LOADOUT_UNAVAILABLE');
const attendanceGet = plainHandler(
  (sql, actor) => sql`select public.get_my_world_attendance_v1(${actor}::uuid) as result`,
  'ATTENDANCE_UNAVAILABLE');
const jeongseokAccessGet = plainHandler(
  (sql, actor) => sql`select public.get_jeongseok_access_v1(${actor}::uuid) as result`,
  'JEONGSEOK_ACCESS_UNAVAILABLE');
const personalRoomGet = plainHandler(
  (sql, actor) => sql`select public.get_or_create_my_personal_room_v1(${actor}::uuid) as result`,
  'PERSONAL_ROOM_UNAVAILABLE');

const handlers = {
  // ---- A-1 reads (kept; the writes schema is a superset) ----
  '/api/world-inventory': plainHandler(
    (sql, actor) => sql`select public.get_my_world_inventory_v1(${actor}::uuid) as result`,
    'INVENTORY_UNAVAILABLE'),
  '/api/world-wallet': plainHandler(
    (sql, actor) => sql`select public.get_my_world_wallet_v1(${actor}::uuid) as result`,
    'WALLET_UNAVAILABLE'),
  '/api/world-progression': plainHandler(
    (sql, actor) => sql`select public.get_my_world_progression_v1(${actor}::uuid) as result`,
    'PROGRESSION_UNAVAILABLE'),
  '/api/world-shop-capabilities': plainHandler(
    (sql, actor) => sql`select public.get_world_shop_capabilities_v1(${actor}::uuid) as result`,
    'SHOP_CAPABILITIES_UNAVAILABLE'),

  // /api/world-shop?shop_id=<id>
  '/api/world-shop': async function handle(request, env) {
    const fallbackCode = 'SHOP_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const shopId = url.searchParams.get('shop_id');
    if (keys.some((k) => k !== 'shop_id') || typeof shopId !== 'string' ||
        shopId === '' || shopId.length > 128) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_world_shop_v1(${actor}::uuid, ${shopId}::text) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // /api/world-staff-badges?ids=<uuid,uuid,...> (1..64).
  '/api/world-staff-badges': async function handle(request, env) {
    const fallbackCode = 'STAFF_BADGES_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const raw = url.searchParams.get('ids');
    const ids = typeof raw === 'string' && raw !== '' ? raw.split(',') : [];
    if (keys.some((k) => k !== 'ids') || ids.length < 1 || ids.length > 64 ||
        ids.some((id) => !SESSION_ID.test(id))) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select * from public.get_world_staff_badges_v1(${actor}::uuid, ${ids}::uuid[])`;
        return json(200, { badges: rows }, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // /api/world-profile: GET reads (A-1 behaviour unchanged); POST creates
  // (BCD: create_my_world_profile_v1). POST body {nickname, departmentId?,
  // avatarKey?}; title is always NULL at creation (D-PROFILE-MAIL.md §2.2).
  // 201 when a profile is created, 200 when one already existed.
  '/api/world-profile': async function handle(request, env) {
    const fallbackCode = 'PROFILE_UNAVAILABLE';
    const headers = baseHeaders();
    if (request.method === 'POST') {
      const blocked = await guard(request, headers, 'POST');
      if (blocked) return blocked;
      const url = new URL(request.url);
      if (url.search) return new Response(null, { status: 400, headers });
      try {
        const actor = await requireSession(request, env, fallbackCode);
        const body = await readJsonBody(request);
        if (body === undefined || body === null || typeof body !== 'object' || Array.isArray(body)) {
          return new Response(null, { status: 400, headers });
        }
        const { nickname, departmentId, avatarKey } = body;
        if (typeof nickname !== 'string' || btNickHasBanned(nickname)) {
          throw new Tier4Error('INVALID_NICKNAME', 400);
        }
        if (departmentId !== undefined && departmentId !== null &&
            (!Number.isSafeInteger(departmentId) || departmentId < 1)) throw bad();
        if (avatarKey !== undefined && avatarKey !== null &&
            !['classic', 'scholar', 'explorer', 'star'].includes(avatarKey)) throw bad();
        const sql = connect(env, 10000);
        try {
          const rows = await sql`select public.create_my_world_profile_v1(${actor}::uuid, ${nickname}::text, ${departmentId ?? null}::bigint, ${avatarKey ?? 'classic'}::text, ${null}::text) as result`;
          const result = rows[0]?.result ?? null;
          if (!result) throw new Tier4Error(fallbackCode, 503);
          return json(result.created ? 201 : 200, result, headers);
        } catch (error) {
          throw mapRpcError(error, fallbackCode);
        }
      } catch (error) {
        return replyError(error, fallbackCode, headers);
      }
    }
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const found = await sql`select user_id, is_banned from public.profiles where user_id = ${actor}::uuid limit 1`;
        if (!found.length || found[0]?.is_banned) {
          throw new Tier4Error('PROFILE_REQUIRED', 409);
        }
        const profileRows = await sql`select public.get_my_profile(${actor}::uuid) as result`;
        const achievementRows = await sql`select public.get_my_achievements(${actor}::uuid) as result`;
        const profile = profileRows[0]?.result ?? null;
        const achievements = achievementRows[0]?.result ?? null;
        if (!profile || !achievements) throw new Tier4Error(fallbackCode, 503);
        return json(200, { ...profile, achievements }, headers);
      } catch (error) {
        if (error instanceof Tier4Error) throw error;
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // ---- A-2 writes ----
  // POST /api/world-loadout {action: 'equip'|'unequip', slot, itemId?, idempotencyKey}
  // GET  /api/world-loadout (A-1 read)
  '/api/world-loadout': async function handle(request, env) {
    if (request.method === 'GET') return loadoutGet(request, env);
    return postHandler('LOADOUT_UNAVAILABLE', async (sql, actor, body) => {
      const { action, slot, itemId, idempotencyKey } = body;
      if (!isKey(idempotencyKey)) throw bad();
      if (typeof slot !== 'string' || slot === '' || slot.length > 40) throw bad();
      if (action === 'equip') {
        if (typeof itemId !== 'string' || itemId === '' || itemId.length > 80) throw bad();
        return rpcResult(sql`select public.equip_my_world_item_v1(${actor}::uuid, ${slot}::text, ${itemId}::text, ${idempotencyKey}::text) as result`);
      }
      if (action === 'unequip') {
        return rpcResult(sql`select public.unequip_my_world_item_v1(${actor}::uuid, ${slot}::text, ${idempotencyKey}::text) as result`);
      }
      throw bad();
    })(request, env);
  },

  // POST /api/world-shop-purchase {listingId, idempotencyKey, shopId?}
  // shopId present -> v2 (scoped, original client rule); absent -> v1.
  '/api/world-shop-purchase': postHandler('SHOP_PURCHASE_UNAVAILABLE', async (sql, actor, body) => {
    const { listingId, idempotencyKey, shopId } = body;
    if (typeof listingId !== 'string' || listingId === '' || listingId.length > 120) throw bad();
    if (!isKey(idempotencyKey)) throw bad();
    if (shopId !== undefined && shopId !== null) {
      if (typeof shopId !== 'string' || shopId === '' || shopId.length > 128) throw bad();
      return rpcResult(sql`select public.purchase_world_shop_listing_v2(${actor}::uuid, ${shopId}::text, ${listingId}::text, ${idempotencyKey}::text) as result`);
    }
    return rpcResult(sql`select public.purchase_world_shop_listing_v1(${actor}::uuid, ${listingId}::text, ${idempotencyKey}::text) as result`);
  }),

  // POST /api/world-attendance-claim {} (no body fields; the server day rules)
  // GET  /api/world-attendance
  '/api/world-attendance-claim': postHandler('ATTENDANCE_UNAVAILABLE', async (sql, actor) => {
    return rpcResult(sql`select public.claim_my_world_attendance_v1(${actor}::uuid) as result`);
  }),
  '/api/world-attendance': attendanceGet,

  // POST /api/world-guestbook {action: 'create'|'update'|'delete', content?, entryId?, location?}
  // GET  /api/world-guestbook?limit=&before= (profile required, original RPC rule)
  '/api/world-guestbook': async function handle(request, env) {
    if (request.method === 'GET') {
      const fallbackCode = 'GUESTBOOK_UNAVAILABLE';
      const headers = baseHeaders();
      const blocked = await guardGet(request, headers);
      if (blocked) return blocked;
      const url = new URL(request.url);
      const keys = [...url.searchParams.keys()];
      const limitRaw = url.searchParams.get('limit');
      const before = url.searchParams.get('before');
      const limit = limitRaw === null ? 20 : Number(limitRaw);
      if (keys.some((k) => k !== 'limit' && k !== 'before') ||
          !Number.isSafeInteger(limit) || limit < 1 || limit > 50 ||
          (before !== null && Number.isNaN(Date.parse(before)))) {
        return new Response(null, { status: 400, headers });
      }
      try {
        const actor = await requireSession(request, env, fallbackCode);
        await requireProfile(request, env, actor, fallbackCode);
        const sql = connect(env, 10000);
        try {
          const rows = await sql`select public.get_world_guestbook_v2(${actor}::uuid, 'main_gate'::text, ${limit}::integer, ${before}::timestamptz) as result`;
          return json(200, rows[0]?.result ?? null, headers);
        } catch (error) {
          throw mapRpcError(error, fallbackCode);
        }
      } catch (error) {
        return replyError(error, fallbackCode, headers);
      }
    }
    return postHandler('GUESTBOOK_UNAVAILABLE', async (sql, actor, body) => {
      const { action, content, entryId, location } = body;
      const loc = location === undefined ? 'main_gate' : location;
      if (action === 'create') {
        if (typeof content !== 'string') throw bad();
        return rpcResult(sql`select public.create_world_guestbook_entry_v2(${actor}::uuid, ${content}::text, ${loc}::text) as result`);
      }
      if (action === 'update') {
        if (!isUuid(entryId) || typeof content !== 'string') throw bad();
        return rpcResult(sql`select public.update_world_guestbook_entry_v2(${actor}::uuid, ${entryId}::uuid, ${content}::text) as result`);
      }
      if (action === 'delete') {
        if (!isUuid(entryId)) throw bad();
        const rows = await sql`select public.delete_world_guestbook_entry_v2(${actor}::uuid, ${entryId}::uuid) as result`;
        return rows[0]?.result ?? null;
      }
      throw bad();
    }, { profileRequired: true })(request, env);
  },

  // POST /api/world-jeongseok-pass {passType, idempotencyKey}
  // GET  /api/world-jeongseok-access
  '/api/world-jeongseok-pass': postHandler('JEONGSEOK_PASS_UNAVAILABLE', async (sql, actor, body) => {
    const { passType, idempotencyKey } = body;
    if (typeof passType !== 'string' || passType === '' || passType.length > 80) throw bad();
    if (!isKey(idempotencyKey)) throw bad();
    return rpcResult(sql`select public.purchase_jeongseok_pass_v1(${actor}::uuid, ${passType}::text, ${idempotencyKey}::text) as result`);
  }),
  '/api/world-jeongseok-access': jeongseokAccessGet,

  // POST /api/world-cooking {recipeId, requestId} — requestId is the idempotency key.
  '/api/world-cooking': postHandler('COOKING_UNAVAILABLE', async (sql, actor, body) => {
    const { recipeId, requestId } = body;
    if (typeof recipeId !== 'string' || recipeId === '' || recipeId.length > 80) throw bad();
    if (!isUuid(requestId)) throw bad();
    return rpcResult(sql`select public.cook_my_world_recipe_v1(${actor}::uuid, ${recipeId}::text, ${requestId}::uuid) as result`);
  }),

  // POST /api/world-room-furniture {roomId, revision, objects}
  // GET  /api/world-room-furniture?room_id=
  '/api/world-room-furniture': async function handle(request, env) {
    if (request.method === 'GET') {
      const fallbackCode = 'ROOM_FURNITURE_UNAVAILABLE';
      const headers = baseHeaders();
      const blocked = await guardGet(request, headers);
      if (blocked) return blocked;
      const url = new URL(request.url);
      const keys = [...url.searchParams.keys()];
      const roomId = url.searchParams.get('room_id');
      if (keys.some((k) => k !== 'room_id') || !isUuid(roomId)) {
        return new Response(null, { status: 400, headers });
      }
      try {
        const actor = await requireSession(request, env, fallbackCode);
        const sql = connect(env, 10000);
        try {
          const rows = await sql`select public.get_world_room_furniture_v1(${actor}::uuid, ${roomId}::uuid) as result`;
          return json(200, rows[0]?.result ?? null, headers);
        } catch (error) {
          throw mapRpcError(error, fallbackCode);
        }
      } catch (error) {
        return replyError(error, fallbackCode, headers);
      }
    }
    return postHandler('ROOM_FURNITURE_UNAVAILABLE', async (sql, actor, body) => {
      const { roomId, revision, objects } = body;
      if (!isUuid(roomId)) throw bad();
      if (!Number.isSafeInteger(revision) || revision < 0) throw bad();
      if (!Array.isArray(objects)) throw bad();
      // The RPC validates the layout; the Worker only passes the JSON through.
      return rpcResult(sql`select public.save_my_room_furniture_v1(${actor}::uuid, ${roomId}::uuid, ${revision}::integer, ${JSON.stringify(objects)}::jsonb) as result`);
    })(request, env);
  },

  // POST /api/world-personal-room {action: 'ensure'|'setVisibility', visibility?}
  // GET  /api/world-personal-room (ensure)
  '/api/world-personal-room': async function handle(request, env) {
    if (request.method === 'GET') return personalRoomGet(request, env);
    return postHandler('PERSONAL_ROOM_UNAVAILABLE', async (sql, actor, body) => {
      const { action, visibility } = body;
      if (action === 'ensure') {
        return rpcResult(sql`select public.get_or_create_my_personal_room_v1(${actor}::uuid) as result`);
      }
      if (action === 'setVisibility') {
        if (visibility !== 'private' && visibility !== 'friends') throw bad();
        return rpcResult(sql`select public.set_my_personal_room_visibility_v1(${actor}::uuid, ${visibility}::text) as result`);
      }
      throw bad();
    })(request, env);
  },

  // POST /api/world-room-knock {action: 'knock'|'get'|'list'|'respond',
  //   ownerUserId?, knockId?, accept?} — polling only; see the file header.
  '/api/world-room-knock': postHandler('ROOM_KNOCK_UNAVAILABLE', async (sql, actor, body) => {
    const { action, ownerUserId, knockId, accept } = body;
    if (action === 'knock') {
      if (!isUuid(ownerUserId)) throw bad();
      return rpcResult(sql`select public.knock_friend_personal_room_v1(${actor}::uuid, ${ownerUserId}::uuid) as result`);
    }
    if (action === 'get') {
      if (!isUuid(knockId)) throw bad();
      return rpcResult(sql`select public.get_my_room_knock_v1(${actor}::uuid, ${knockId}::uuid) as result`);
    }
    if (action === 'list') {
      return rpcResult(sql`select public.list_my_room_knocks_v1(${actor}::uuid) as result`);
    }
    if (action === 'respond') {
      if (!isUuid(knockId) || typeof accept !== 'boolean') throw bad();
      return rpcResult(sql`select public.respond_room_knock_v1(${actor}::uuid, ${knockId}::uuid, ${accept}::boolean) as result`);
    }
    throw bad();
  }, { profileRequired: true }),

  // ---- A-3 state machines ----
  // Daily quiz: GET state / POST start / POST answer {runId, questionId, answerIndex}.
  // The quiz client answers the current question (index = answered count);
  // the server checks the question id, the 0..3 answer range and the run.
  '/api/world-daily-quiz': plainHandler(
    (sql, actor) => sql`select public.get_my_world_daily_quiz_v1(${actor}::uuid) as result`,
    'DAILY_QUIZ_UNAVAILABLE'),
  '/api/world-daily-quiz-start': postHandler('DAILY_QUIZ_UNAVAILABLE', async (sql, actor) => {
    return rpcResult(sql`select public.start_my_world_daily_quiz_v1(${actor}::uuid) as result`);
  }),
  '/api/world-daily-quiz-answer': postHandler('DAILY_QUIZ_UNAVAILABLE', async (sql, actor, body) => {
    const { runId, questionId, answerIndex } = body;
    if (!isUuid(runId)) throw bad();
    if (typeof questionId !== 'string' || questionId === '' || questionId.length > 80) throw bad();
    if (!Number.isSafeInteger(answerIndex) || answerIndex < 0 || answerIndex > 3) throw bad();
    return rpcResult(sql`select public.answer_my_world_daily_quiz_v1(${actor}::uuid, ${runId}::uuid, ${questionId}::text, ${answerIndex}::smallint) as result`);
  }),

  // Life skills: GET skills / GET tree?skill_id= / POST unlock / POST reset.
  // unlock/reset take requestId (uuid) as the idempotency key.
  '/api/world-life-skills': plainHandler(
    (sql, actor) => sql`select public.get_my_world_life_skills_v1(${actor}::uuid) as result`,
    'LIFE_SKILLS_UNAVAILABLE'),
  '/api/world-life-skill-tree': async function handle(request, env) {
    const fallbackCode = 'LIFE_SKILLS_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const skillId = url.searchParams.get('skill_id');
    if (keys.some((k) => k !== 'skill_id') || typeof skillId !== 'string' ||
        skillId === '' || skillId.length > 80) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_my_world_life_skill_tree_v1(${actor}::uuid, ${skillId}::text) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },
  '/api/world-life-node-unlock': postHandler('LIFE_SKILLS_UNAVAILABLE', async (sql, actor, body) => {
    const { nodeId, requestId } = body;
    if (typeof nodeId !== 'string' || nodeId === '' || nodeId.length > 80) throw bad();
    if (!isUuid(requestId)) throw bad();
    return rpcResult(sql`select public.unlock_my_world_life_node_v1(${actor}::uuid, ${nodeId}::text, ${requestId}::uuid) as result`);
  }),
  '/api/world-life-tree-reset': postHandler('LIFE_SKILLS_UNAVAILABLE', async (sql, actor, body) => {
    const { skillId, requestId } = body;
    if (typeof skillId !== 'string' || skillId === '' || skillId.length > 80) throw bad();
    if (!isUuid(requestId)) throw bad();
    return rpcResult(sql`select public.reset_my_world_life_tree_v1(${actor}::uuid, ${skillId}::text, ${requestId}::uuid) as result`);
  }),

  // Social: GET board / GET public profile?target= / GET relationship?target=
  // / POST friend-request {action, target, accept?} / POST report-user
  // / POST block-user {action: block|unblock, target}. All profile-gated:
  // the original RPCs enforce it through world_social_caller.
  '/api/world-social': plainHandlerProfile(
    (sql, actor) => sql`select public.get_my_world_social(${actor}::uuid) as result`,
    'SOCIAL_UNAVAILABLE'),
  '/api/world-public-profile': async function handle(request, env) {
    const fallbackCode = 'SOCIAL_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const target = url.searchParams.get('target');
    if (keys.some((k) => k !== 'target') || !isUuid(target)) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      await requireProfile(request, env, actor, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_world_public_profile(${actor}::uuid, ${target}::uuid) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },
  '/api/world-relationship': async function handle(request, env) {
    const fallbackCode = 'SOCIAL_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const target = url.searchParams.get('target');
    if (keys.some((k) => k !== 'target') || !isUuid(target)) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      await requireProfile(request, env, actor, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_world_relationship(${actor}::uuid, ${target}::uuid) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },
  '/api/world-friend-request': postHandler('SOCIAL_UNAVAILABLE', async (sql, actor, body) => {
    const { action, target, accept } = body;
    if (!isUuid(target)) throw bad();
    if (action === 'send') {
      return rpcResult(sql`select public.send_world_friend_request(${actor}::uuid, ${target}::uuid) as result`);
    }
    if (action === 'respond') {
      if (typeof accept !== 'boolean') throw bad();
      return rpcResult(sql`select public.respond_world_friend_request(${actor}::uuid, ${target}::uuid, ${accept}::boolean) as result`);
    }
    if (action === 'cancel') {
      return rpcResult(sql`select public.cancel_world_friend_request(${actor}::uuid, ${target}::uuid) as result`);
    }
    if (action === 'remove') {
      return rpcResult(sql`select public.remove_world_friend(${actor}::uuid, ${target}::uuid) as result`);
    }
    throw bad();
  }, { profileRequired: true }),
  '/api/world-report-user': postHandler('SOCIAL_UNAVAILABLE', async (sql, actor, body) => {
    const { target, category, placeZoneId } = body;
    if (!isUuid(target)) throw bad();
    if (typeof category !== 'string' || category === '' || category.length > 40) throw bad();
    if (placeZoneId !== undefined && placeZoneId !== null &&
        (typeof placeZoneId !== 'string' || placeZoneId.length > 80)) throw bad();
    return rpcResult(sql`select public.report_world_user(${actor}::uuid, ${target}::uuid, ${category}::text, ${placeZoneId ?? null}::text) as result`);
  }, { profileRequired: true }),
  '/api/world-block-user': postHandler('SOCIAL_UNAVAILABLE', async (sql, actor, body) => {
    const { action, target } = body;
    if (!isUuid(target)) throw bad();
    if (action === 'block') {
      return rpcResult(sql`select public.block_world_user(${actor}::uuid, ${target}::uuid) as result`);
    }
    if (action === 'unblock') {
      return rpcResult(sql`select public.unblock_world_user(${actor}::uuid, ${target}::uuid) as result`);
    }
    throw bad();
  }, { profileRequired: true }),

  // Accompany: GET sessions / POST {action: propose|respond|end,
  //   target?, poiId?, placeZoneId?, sessionId?, accept?}. Profile-gated.
  '/api/world-accompany': async function handle(request, env) {
    if (request.method === 'GET') {
      return plainHandlerProfile(
        (sql, actor) => sql`select public.get_my_world_accompany(${actor}::uuid) as result`,
        'ACCOMPANY_UNAVAILABLE')(request, env);
    }
    return postHandler('ACCOMPANY_UNAVAILABLE', async (sql, actor, body) => {
      const { action, target, poiId, placeZoneId, sessionId, accept } = body;
      if (action === 'propose') {
        if (!isUuid(target)) throw bad();
        if (typeof poiId !== 'string' || poiId === '' || poiId.length > 80) throw bad();
        if (typeof placeZoneId !== 'string' || placeZoneId === '' || placeZoneId.length > 80) throw bad();
        return rpcResult(sql`select public.propose_world_accompany(${actor}::uuid, ${target}::uuid, ${poiId}::text, ${placeZoneId}::text) as result`);
      }
      if (action === 'respond') {
        if (!isUuid(sessionId) || typeof accept !== 'boolean') throw bad();
        return rpcResult(sql`select public.respond_world_accompany(${actor}::uuid, ${sessionId}::uuid, ${accept}::boolean) as result`);
      }
      if (action === 'end') {
        if (!isUuid(sessionId)) throw bad();
        return rpcResult(sql`select public.end_world_accompany(${actor}::uuid, ${sessionId}::uuid) as result`);
      }
      throw bad();
    }, { profileRequired: true })(request, env);
  },

  // Biryong progress: GET / POST {progress, migratedFromLocal?}.
  '/api/world-biryong-progress': async function handle(request, env) {
    if (request.method === 'GET') {
      return plainHandler(
        (sql, actor) => sql`select public.get_my_biryong_progress_v1(${actor}::uuid) as result`,
        'BIRYONG_PROGRESS_UNAVAILABLE')(request, env);
    }
    return postHandler('BIRYONG_PROGRESS_UNAVAILABLE', async (sql, actor, body) => {
      const { progress, migratedFromLocal } = body;
      if (progress === null || typeof progress !== 'object' || Array.isArray(progress)) throw bad();
      if (migratedFromLocal !== undefined && typeof migratedFromLocal !== 'boolean') throw bad();
      return rpcResult(sql`select public.merge_my_biryong_progress_v1(${actor}::uuid, ${JSON.stringify(progress)}::jsonb, ${migratedFromLocal ?? false}::boolean) as result`);
    })(request, env);
  },

  // Biryong NPC relationships: GET one?npc_id= / GET list
  // / POST advance {npcId, targetStage, sourceType, sourceRef, resultRef, idempotencyKey}.
  '/api/world-biryong-npc-relationship': async function handle(request, env) {
    const fallbackCode = 'BIRYONG_RELATIONSHIP_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const npcId = url.searchParams.get('npc_id');
    if (keys.some((k) => k !== 'npc_id') || typeof npcId !== 'string' ||
        npcId === '' || npcId.length > 80) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_my_biryong_npc_relationship_v1(${actor}::uuid, ${npcId}::text) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },
  '/api/world-biryong-npc-relationships': plainHandler(
    (sql, actor) => sql`select public.get_my_biryong_npc_relationships_v1(${actor}::uuid) as result`,
    'BIRYONG_RELATIONSHIP_UNAVAILABLE'),
  '/api/world-biryong-npc-advance': postHandler('BIRYONG_RELATIONSHIP_UNAVAILABLE', async (sql, actor, body) => {
    const { npcId, targetStage, sourceType, sourceRef, resultRef, idempotencyKey } = body;
    if (typeof npcId !== 'string' || npcId === '' || npcId.length > 80) throw bad();
    if (!Number.isSafeInteger(targetStage)) throw bad();
    for (const v of [sourceType, sourceRef]) {
      if (typeof v !== 'string' || v === '' || v.length > 120) throw bad();
    }
    // resultRef is nullable: QUEST/EVENT require it, SYSTEM does not (the RPC
    // raises RELATIONSHIP_RESULT_REF_REQUIRED when it is missing for those).
    if (resultRef !== null && resultRef !== undefined &&
        (typeof resultRef !== 'string' || resultRef === '' || resultRef.length > 120)) throw bad();
    if (!isKey(idempotencyKey)) throw bad();
    return rpcResult(sql`select public.world_biryong_npc_relationship_advance_v1(${actor}::uuid, ${npcId}::text, ${targetStage}::smallint, ${sourceType}::text, ${sourceRef}::text, ${resultRef ?? null}::text, ${idempotencyKey}::text) as result`);
  }),

  // Campus NPC relationships: GET one?npc_id= / GET list
  // / POST apply {npcId, definitionVersion, eventType, signal, occurrence,
  //   requestedDelta, sourceType, sourceRef, idempotencyKey}.
  '/api/world-campus-npc-relationship': async function handle(request, env) {
    const fallbackCode = 'CAMPUS_NPC_RELATIONSHIP_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    const keys = [...url.searchParams.keys()];
    const npcId = url.searchParams.get('npc_id');
    if (keys.some((k) => k !== 'npc_id') || typeof npcId !== 'string' ||
        npcId === '' || npcId.length > 80) {
      return new Response(null, { status: 400, headers });
    }
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_my_world_campus_npc_relationship_v1(${actor}::uuid, ${npcId}::text) as result`;
        return json(200, rows[0]?.result ?? null, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },
  '/api/world-campus-npc-relationships': plainHandler(
    (sql, actor) => sql`select public.get_my_world_campus_npc_relationships_v1(${actor}::uuid) as result`,
    'CAMPUS_NPC_RELATIONSHIP_UNAVAILABLE'),
  '/api/world-campus-npc-apply': postHandler('CAMPUS_NPC_RELATIONSHIP_UNAVAILABLE', async (sql, actor, body) => {
    const { npcId, definitionVersion, eventType, signal, occurrence, requestedDelta, sourceType, sourceRef, idempotencyKey } = body;
    if (typeof npcId !== 'string' || npcId === '' || npcId.length > 80) throw bad();
    if (!Number.isSafeInteger(definitionVersion) || !Number.isSafeInteger(occurrence) ||
        !Number.isSafeInteger(requestedDelta)) throw bad();
    for (const v of [eventType, sourceType, sourceRef]) {
      if (typeof v !== 'string' || v === '' || v.length > 120) throw bad();
    }
    // signal is nullable in the RPC (FIRST_MEETING / NEGATIVE_CHOICE carry no
    // signal); when present it must be a non-empty string (the RPC checks the
    // ^[A-Z][A-Z0-9_]{1,63}$ shape and raises INVALID_RELATIONSHIP_SIGNAL).
    if (signal !== null && signal !== undefined &&
        (typeof signal !== 'string' || signal === '' || signal.length > 120)) throw bad();
    if (!isKey(idempotencyKey)) throw bad();
    return rpcResult(sql`select public.world_campus_npc_relationship_apply_v1(${actor}::uuid, ${npcId}::text, ${definitionVersion}::integer, ${eventType}::text, ${signal ?? null}::text, ${occurrence}::integer, ${requestedDelta}::smallint, ${sourceType}::text, ${sourceRef}::text, ${idempotencyKey}::text) as result`);
  }),

  // MCM 2026 event: GET state / POST landlord-run {} / POST landlord-choice
  // {runId, actorId} / POST claim {claim: 'main'|'landlord_first_clear'}.
  // The event window in the seed is ENDED (2026-09-29..30); tests flip it
  // ACTIVE as a fixture, like the A-2 jeongseok gate flip.
  '/api/world-mcm-event': plainHandler(
    (sql, actor) => sql`select public.get_my_mcm_2026_event_v1(${actor}::uuid) as result`,
    'MCM_EVENT_UNAVAILABLE'),
  '/api/world-mcm-landlord-run': postHandler('MCM_EVENT_UNAVAILABLE', async (sql, actor) => {
    return rpcResult(sql`select public.start_mcm_landlord_run_v1(${actor}::uuid) as result`);
  }),
  '/api/world-mcm-landlord-choice': postHandler('MCM_EVENT_UNAVAILABLE', async (sql, actor, body) => {
    const { runId, actorId } = body;
    if (!isUuid(runId)) throw bad();
    if (typeof actorId !== 'string' || actorId === '' || actorId.length > 40) throw bad();
    return rpcResult(sql`select public.submit_mcm_landlord_choice_v1(${actor}::uuid, ${runId}::uuid, ${actorId}::text) as result`);
  }),
  '/api/world-mcm-claim': postHandler('MCM_EVENT_UNAVAILABLE', async (sql, actor, body) => {
    const { claim } = body;
    if (claim === 'main') {
      return rpcResult(sql`select public.claim_my_mcm_2026_main_reward_v1(${actor}::uuid) as result`);
    }
    if (claim === 'landlord_first_clear') {
      return rpcResult(sql`select public.claim_my_mcm_landlord_first_clear_reward_v1(${actor}::uuid) as result`);
    }
    throw bad();
  }),

  // ---- BCD: mail verification (D-1 (c) manual-admin fallback) ----
  // POST /api/world-mail-verify-request {email} -> 201 (new) / 200 (duplicate
  // within 10 min). No mail is sent on this path; the row is the admin queue.
  '/api/world-mail-verify-request': async function handle(request, env) {
    const fallbackCode = 'MAIL_VERIFY_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guard(request, headers, 'POST');
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const actor = await requireSession(request, env, fallbackCode);
      const body = await readJsonBody(request);
      if (body === undefined || body === null || typeof body !== 'object' || Array.isArray(body)) {
        return new Response(null, { status: 400, headers });
      }
      const { email } = body;
      if (typeof email !== 'string' || email.length > 120) throw bad();
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.request_world_mail_verification_v1(${actor}::uuid, ${email}::text) as result`;
        const result = rows[0]?.result ?? null;
        if (!result) throw new Tier4Error(fallbackCode, 503);
        return json(result.duplicate ? 200 : 201, result, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // POST /api/world-mail-verify-claim {requestId} + X-Admin-Key: <secret>.
  // The admin key is the Worker secret MAIL_ADMIN_KEY, never in code, a
  // log, or a response. Wrong/missing key is 403; the RPC additionally
  // refuses non-pending/unknown requests with 404 MAIL_REQUEST_NOT_FOUND.
  '/api/world-mail-verify-claim': async function handle(request, env) {
    const fallbackCode = 'MAIL_VERIFY_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guard(request, headers, 'POST');
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    const adminKey = env.MAIL_ADMIN_KEY;
    const presented = request.headers.get('x-admin-key') ?? '';
    if (!adminKey || presented.length !== adminKey.length || presented !== adminKey) {
      return json(403, { error: 'FORBIDDEN' }, headers);
    }
    try {
      const body = await readJsonBody(request);
      if (body === undefined || body === null || typeof body !== 'object' || Array.isArray(body)) {
        return new Response(null, { status: 400, headers });
      }
      const { requestId } = body;
      if (!isUuid(requestId)) throw bad();
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.admin_claim_world_mail_verification_v1(${requestId}::uuid) as result`;
        const result = rows[0]?.result ?? null;
        if (!result) throw new Tier4Error(fallbackCode, 503);
        return json(200, result, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // ---- BCD: online heartbeat / count (C-1 (b) HTTP polling) ----
  // POST /api/world-online-touch {placeZoneId?, space?, visitorId?} -> 200
  // {ok:true}. The heartbeat session id IS the guest session id (C-3):
  // requireSession already enforces that it exists in public.sessions.
  // The 10-second per-session rate limit lives in the RPC (429).
  '/api/world-online-touch': postHandler('ONLINE_TOUCH_UNAVAILABLE', async (sql, actor, body) => {
    const { placeZoneId, space, visitorId } = body;
    if (placeZoneId !== undefined && placeZoneId !== null &&
        (typeof placeZoneId !== 'string' || placeZoneId === '' || placeZoneId.length > 60)) throw bad();
    if (space !== undefined && space !== null &&
        (typeof space !== 'string' || !['lobby', 'campus', 'club_room', 'housing_lobby', 'personal_room'].includes(space))) throw bad();
    if (visitorId !== undefined && visitorId !== null && !isUuid(visitorId)) throw bad();
    await sql`select public.touch_world_online_session_v2(${actor}::uuid, ${visitorId ?? null}::uuid, ${placeZoneId ?? null}::text, ${space ?? 'campus'}::text)`;
    return { ok: true };
  }),

  // GET /api/world-online-count (no session: the origin RPC is anon-callable).
  // 5-second Worker-local cache (C-2); asOf is the cache time.
  '/api/world-online-count': async function handle(request, env) {
    const fallbackCode = 'ONLINE_COUNT_UNAVAILABLE';
    const headers = baseHeaders();
    const blocked = await guardGet(request, headers);
    if (blocked) return blocked;
    const url = new URL(request.url);
    if (url.search) return new Response(null, { status: 400, headers });
    try {
      const now = Date.now();
      if (onlineCountCache.body && now - onlineCountCache.at < 5000) {
        return json(200, onlineCountCache.body, headers);
      }
      const sql = connect(env, 10000);
      try {
        const rows = await sql`select public.get_world_online_count_v1() as result`;
        const result = rows[0]?.result ?? null;
        if (!result) throw new Tier4Error(fallbackCode, 503);
        onlineCountCache = { at: now, body: result };
        return json(200, result, headers);
      } catch (error) {
        throw mapRpcError(error, fallbackCode);
      }
    } catch (error) {
      return replyError(error, fallbackCode, headers);
    }
  },

  // ---- B-3 (B-DECISION.md): NPC AI / relationship / quest, model-convert
  // and JEV have NO handler here by design. Any call to /api/npc-ai,
  // /api/npc-relationship, /api/world-quest, /api/model-convert or
  // /api/npc-dialogue-route falls through to the default 404 below, and the
  // client probe treats 404 as "feature off". Nothing is proxied upstream.
};

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (Object.prototype.hasOwnProperty.call(handlers, pathname)) {
      return handlers[pathname](request, env);
    }
    return new Response('Not found', { status: 404 });
  },
};
