#!/usr/bin/env python3
"""Generate the Tier 4 (A-3) clients from the pristine snapshot.

Reads the originals from ~/workspace/inha-world-static-test/src (never
modified), applies the Tier 4 A-3 transport replacements, and writes the
migrated clients into this folder (client/ mirrors src/):

  daily-quiz/daily-quiz-client.js   GET /api/world-daily-quiz, POST start/answer
  life-skills/life-skill-book-client.js
                                   GET /api/world-life-skills, GET tree?skill_id=,
                                   POST unlock/reset
  social/social-client.js          GET /api/world-social, GET public-profile /
                                   relationship, POST friend-request / report-user /
                                   block-user
  social/accompany-client.js       GET /api/world-accompany, POST (propose/respond/end)
  biryong/biryong-cloud-sync.js    GET/POST /api/world-biryong-progress
  biryong/biryong-village-relationship-client.js
                                   GET /api/world-biryong-npc-relationships
  events/event-client.js           GET /api/world-mcm-event, POST landlord-run /
                                   landlord-choice / mcm-claim
  events/event-data.js, events/event-phase.js, event-registry.js
                                   verbatim copies (MCM client dependencies)

Only the transport changed: every `client.rpc(name, args)` becomes a
same-host fetch with the `X-Session-Id` header only (A-2 idiom). Parsing,
state, generation, idempotency and reward rules are unchanged.

Deliberately NOT created (see README.md):
  - campus NPC relationship client: no original client file exists.
  - biryong NPC advance client: the original relationship client is
    read-only by design ("deliberately NO mutation method").
  - MCM advance client call: advance_mcm_2026_event_v1 is server-only
    (no HTTP endpoint); the migrated event client throws
    MCM_ADVANCE_UNAVAILABLE for a live advance.

Usage: python3 make-clients-a3.py
Verifies every replacement applied exactly once, then node --check on
every written file.
"""
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
SNAP = HOME / "workspace" / "inha-world-static-test" / "src"
HERE = Path(__file__).resolve().parent


def apply(text, replacements, label):
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            print(f"FAIL {label}: expected 1 occurrence, found {count}: {old[:90]!r}")
            sys.exit(1)
        text = text.replace(old, new)
    return text


def write(rel, text):
    out = HERE / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {rel} ({out.stat().st_size} bytes)")


def node_check(rel):
    r = subprocess.run(["node", "--check", str(HERE / rel)], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FAIL node --check {rel}:\n{r.stdout}{r.stderr}")
        sys.exit(1)


# ---------------------------------------------------------------- daily quiz
QUIZ_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — READ + START + ANSWER, A-3): all three paths
// authenticate with the v0.1 guest session id in the `X-Session-Id` header only — no other
// credential header is sent. The id is read lazily by readGuestSessionId() (the single source;
// null when absent — never fabricated). Read: GET /api/world-daily-quiz. Start:
// POST /api/world-daily-quiz-start (empty body). Answer: POST /api/world-daily-quiz-answer
// { runId, questionId, answerIndex }. The server answers 200 + the quiz state, or an HTTP
// status with { error: <server refusal code> }.
// Before: the client called getClient().rpc() on the signed-in permanent-account client
// (get_my_world_daily_quiz_v1 / start_my_world_daily_quiz_v1 / answer_my_world_daily_quiz_v1).
// That path is gone; only the transport changed — parsing, state, generation and the
// reward/replay rules are unchanged.
"""
QUIZ = apply((SNAP / "daily-quiz/daily-quiz-client.js").read_text(), [
    (
        'import { isQuestRewardResult } from "../../npc-factory/quest-reward-shape.mjs";',
        'import { isQuestRewardResult } from "../npc-factory/quest-reward-shape.mjs";\n'
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + QUIZ_AUTH,
    ),
    (
        'export const DAILY_QUIZ_STATE = Object.freeze({',
        'export const DAILY_QUIZ_API_PATH = "/api/world-daily-quiz";\n'
        'export const DAILY_QUIZ_START_API_PATH = "/api/world-daily-quiz-start";\n'
        'export const DAILY_QUIZ_ANSWER_API_PATH = "/api/world-daily-quiz-answer";\n\n'
        'export const DAILY_QUIZ_STATE = Object.freeze({',
    ),
    (
        '/**\n'
        ' * @param {{ getClient: () => ({ rpc: Function } | null), onReward?: (reward: object) => void, onRecoveryReadback?: () => void }} options\n'
        ' *   getClient returns the signed-in permanent-account Supabase client (online.supabase), or null.\n'
        ' *   onReward is called once with the server Reward result of the PASSED answer, for the current account.\n'
        ' */\n'
        'export function createDailyQuizClient({ getClient, onReward = () => {}, onRecoveryReadback = () => {} } = {}) {\n'
        '  if (typeof getClient !== "function") throw new Error("Daily quiz client requires getClient");',
        '/**\n'
        ' * @param {{ getSessionId?: () => (string | null | Promise<string | null>), fetcher?: Function, endpoint?: string, startEndpoint?: string, answerEndpoint?: string, onReward?: (reward: object) => void, onRecoveryReadback?: () => void }} options\n'
        ' *   getSessionId supplies the v0.1 guest session id for all three paths (defaults to\n'
        ' *   readGuestSessionId — the single source; never copied). fetcher defaults to global\n'
        ' *   fetch. The account bound by setAccount IS that session id.\n'
        ' *   onReward is called once with the server Reward result of the PASSED answer, for the current account.\n'
        ' */\n'
        'export function createDailyQuizClient({ getSessionId = readGuestSessionId, fetcher = (...args) => globalThis.fetch(...args), endpoint = DAILY_QUIZ_API_PATH, startEndpoint = DAILY_QUIZ_START_API_PATH, answerEndpoint = DAILY_QUIZ_ANSWER_API_PATH, onReward = () => {}, onRecoveryReadback = () => {} } = {}) {',
    ),
    (
        '  async function call(rpc, args) {\n'
        '    const client = getClient();\n'
        '    if (!client?.rpc) return { error: { message: "SIGNED_OUT" } };\n'
        '    try {\n'
        '      return (await client.rpc(rpc, args)) ?? {};\n'
        '    } catch (error) {\n'
        '      return { error };\n'
        '    }\n'
        '  }',
        '  async function call(rpc, args) {\n'
        '    let sessionId = null;\n'
        '    try { sessionId = await getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '    if (!sessionId) return { error: { message: "SIGNED_OUT" } };\n'
        '    const isRead = rpc === DAILY_QUIZ_RPC.READ;\n'
        '    const path = isRead ? endpoint : rpc === DAILY_QUIZ_RPC.START ? startEndpoint : answerEndpoint;\n'
        '    const body = isRead ? undefined : rpc === DAILY_QUIZ_RPC.START ? {} : { runId: args?.p_run_id, questionId: args?.p_question_id, answerIndex: args?.p_answer_index };\n'
        '    try {\n'
        '      const response = await fetcher(path, isRead\n'
        '        ? { headers: { "X-Session-Id": sessionId } }\n'
        '        : { method: "POST", headers: { "Content-Type": "application/json", "X-Session-Id": sessionId }, body: JSON.stringify(body) });\n'
        '      const data = await response.json().catch(() => null);\n'
        '      if (!response.ok) {\n'
        '        const code = typeof data?.error === "string" && data.error ? data.error : `HTTP_${response.status}`;\n'
        '        return { error: { message: code } };\n'
        '      }\n'
        '      return { data };\n'
        '    } catch (error) {\n'
        '      return { error };\n'
        '    }\n'
        '  }',
    ),
    (
        '    if (!accountId || !getClient()?.rpc) return { outcome: "SIGNED_OUT" };',
        '    if (!accountId || !(await getSessionId?.())) return { outcome: "SIGNED_OUT" };',
    ),
], "daily-quiz-client.js")
write("daily-quiz/daily-quiz-client.js", QUIZ)

# ---------------------------------------------------------------- life skills
LIFE_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — LIST + TREE + UNLOCK + RESET, A-3): all four
// paths authenticate with the v0.1 guest session id in the `X-Session-Id` header only — no other
// credential header is sent. The id is read lazily by readGuestSessionId() (the single source;
// null when absent — never fabricated). List: GET /api/world-life-skills. Tree:
// GET /api/world-life-skill-tree?skill_id=<id>. Unlock: POST /api/world-life-node-unlock
// { nodeId, requestId }. Reset: POST /api/world-life-tree-reset { skillId, requestId }.
// The server answers 200 + the view, or an HTTP status with { error: <server refusal code> }.
// Before: the client called getClient().rpc() on the signed-in permanent-account client
// (get_my_world_life_skills_v1 / get_my_world_life_skill_tree_v1 / unlock_my_world_life_node_v1
// / reset_my_world_life_tree_v1). That path is gone; only the transport changed — parsing,
// state, generation and the request-id replay rules are unchanged.
"""
LIFE = apply((SNAP / "life-skills/life-skill-book-client.js").read_text(), [
    (
        'export const LIFE_SKILL_BOOK_RPC = Object.freeze({',
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + LIFE_AUTH +
        'export const LIFE_SKILL_BOOK_RPC = Object.freeze({',
    ),
    (
        'export const LIFE_SKILL_BOOK_STATE = Object.freeze({',
        'export const LIFE_SKILLS_API_PATH = "/api/world-life-skills";\n'
        'export const LIFE_SKILL_TREE_API_PATH = "/api/world-life-skill-tree";\n'
        'export const LIFE_NODE_UNLOCK_API_PATH = "/api/world-life-node-unlock";\n'
        'export const LIFE_TREE_RESET_API_PATH = "/api/world-life-tree-reset";\n\n'
        'export const LIFE_SKILL_BOOK_STATE = Object.freeze({',
    ),
    (
        '/**\n'
        ' * @param {{ getClient: () => ({ rpc: Function } | null), requestIdFactory?: () => string | null }} options\n'
        ' */\n'
        'export function createLifeSkillBookClient({\n'
        '  getClient,\n'
        '  requestIdFactory = () => globalThis.crypto?.randomUUID?.() ?? null\n'
        '} = {}) {\n'
        '  if (typeof getClient !== "function") throw new Error("Life Skill Book client requires getClient");',
        '/**\n'
        ' * @param {{ getSessionId?: () => (string | null | Promise<string | null>), fetcher?: Function, endpoint?: string, treeEndpoint?: string, unlockEndpoint?: string, resetEndpoint?: string, requestIdFactory?: () => string | null }} options\n'
        ' *   getSessionId supplies the v0.1 guest session id for all four paths (defaults to\n'
        ' *   readGuestSessionId — the single source; never copied). fetcher defaults to global\n'
        ' *   fetch. The account bound by setAccount IS that session id.\n'
        ' */\n'
        'export function createLifeSkillBookClient({\n'
        '  getSessionId = readGuestSessionId,\n'
        '  fetcher = (...args) => globalThis.fetch(...args),\n'
        '  endpoint = LIFE_SKILLS_API_PATH,\n'
        '  treeEndpoint = LIFE_SKILL_TREE_API_PATH,\n'
        '  unlockEndpoint = LIFE_NODE_UNLOCK_API_PATH,\n'
        '  resetEndpoint = LIFE_TREE_RESET_API_PATH,\n'
        '  requestIdFactory = () => globalThis.crypto?.randomUUID?.() ?? null\n'
        '} = {}) {',
    ),
    (
        '  async function call(rpc, args) {\n'
        '    const client = getClient();\n'
        '    if (!client?.rpc) return { error: { message: "SIGNED_OUT" } };\n'
        '    try {\n'
        '      return args === undefined ? await client.rpc(rpc) : await client.rpc(rpc, args);\n'
        '    } catch (error) {\n'
        '      return { error };\n'
        '    }\n'
        '  }',
        '  async function call(rpc, args) {\n'
        '    let sessionId = null;\n'
        '    try { sessionId = await getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '    if (!sessionId) return { error: { message: "SIGNED_OUT" } };\n'
        '    const isList = rpc === LIFE_SKILL_BOOK_RPC.LIST;\n'
        '    const isTree = rpc === LIFE_SKILL_BOOK_RPC.TREE;\n'
        '    const path = isList ? endpoint : isTree ? `${treeEndpoint}?skill_id=${encodeURIComponent(args?.p_skill_id ?? "")}` : rpc === LIFE_SKILL_BOOK_RPC.UNLOCK ? unlockEndpoint : resetEndpoint;\n'
        '    const body = isList || isTree ? undefined : rpc === LIFE_SKILL_BOOK_RPC.UNLOCK ? { nodeId: args?.p_node_id, requestId: args?.p_request_id } : { skillId: args?.p_skill_id, requestId: args?.p_request_id };\n'
        '    try {\n'
        '      const response = await fetcher(path, isList || isTree\n'
        '        ? { headers: { "X-Session-Id": sessionId } }\n'
        '        : { method: "POST", headers: { "Content-Type": "application/json", "X-Session-Id": sessionId }, body: JSON.stringify(body) });\n'
        '      const data = await response.json().catch(() => null);\n'
        '      if (!response.ok) {\n'
        '        const code = typeof data?.error === "string" && data.error ? data.error : `HTTP_${response.status}`;\n'
        '        return { error: { message: code } };\n'
        '      }\n'
        '      return { data };\n'
        '    } catch (error) {\n'
        '      return { error };\n'
        '    }\n'
        '  }',
    ),
    (
        '    if (!accountId || !getClient()?.rpc) return { outcome: "SIGNED_OUT" };',
        '    if (!accountId || !(await getSessionId?.())) return { outcome: "SIGNED_OUT" };',
    ),
], "life-skill-book-client.js")
write("life-skills/life-skill-book-client.js", LIFE)

# ---------------------------------------------------------------- social
SOCIAL_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — A-3): every path authenticates with the v0.1
// guest session id in the `X-Session-Id` header only — no other credential header is sent.
// The id is read lazily by readGuestSessionId() (the single source; null when absent — never
// fabricated). The caller passes the same id as getSelfUserId (Tier 4: the session IS the
// account). Reads: GET /api/world-social, GET /api/world-public-profile?target=<uuid>,
// GET /api/world-relationship?target=<uuid>. Mutations: POST /api/world-friend-request
// { action: send|respond|cancel|remove, target, accept? }, POST /api/world-report-user
// { target, category, placeZoneId }, POST /api/world-block-user { action: block|unblock, target }.
// The server answers 200 + the result, or an HTTP status with { error: <server refusal code> }.
// A missing profile answers 409 PROFILE_NOT_FOUND (added to KNOWN_ERRORS so the UI can show it).
// Before: the client called getClient().rpc() on the signed-in permanent-account client.
// That path is gone; only the transport changed — parsing, dedup, generation and the
// relationship cache rules are unchanged.
"""
SOCIAL = apply((SNAP / "social/social-client.js").read_text(), [
    (
        'export const Relationship = Object.freeze({',
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + SOCIAL_AUTH +
        'export const SOCIAL_API_PATH = "/api/world-social";\n'
        'export const SOCIAL_PUBLIC_PROFILE_API_PATH = "/api/world-public-profile";\n'
        'export const SOCIAL_RELATIONSHIP_API_PATH = "/api/world-relationship";\n'
        'export const SOCIAL_FRIEND_REQUEST_API_PATH = "/api/world-friend-request";\n'
        'export const SOCIAL_REPORT_API_PATH = "/api/world-report-user";\n'
        'export const SOCIAL_BLOCK_API_PATH = "/api/world-block-user";\n\n'
        '// RPC name -> Tier 4 request. GETs carry the target in the query; POSTs carry the\n'
        '// action and target in the JSON body (the Worker maps them back to the RPCs).\n'
        'function socialRequest(name, args, sessionId) {\n'
        '  const get = (path) => ({ path, init: { headers: { "X-Session-Id": sessionId } } });\n'
        '  const post = (path, body) => ({ path, init: { method: "POST", headers: { "Content-Type": "application/json", "X-Session-Id": sessionId }, body: JSON.stringify(body) } });\n'
        '  switch (name) {\n'
        '    case "get_my_world_social": return get(SOCIAL_API_PATH);\n'
        '    case "get_world_public_profile": return get(`${SOCIAL_PUBLIC_PROFILE_API_PATH}?target=${encodeURIComponent(args.p_target)}`);\n'
        '    case "get_world_relationship": return get(`${SOCIAL_RELATIONSHIP_API_PATH}?target=${encodeURIComponent(args.p_target)}`);\n'
        '    case "send_world_friend_request": return post(SOCIAL_FRIEND_REQUEST_API_PATH, { action: "send", target: args.p_target });\n'
        '    case "respond_world_friend_request": return post(SOCIAL_FRIEND_REQUEST_API_PATH, { action: "respond", target: args.p_target, accept: args.p_accept });\n'
        '    case "cancel_world_friend_request": return post(SOCIAL_FRIEND_REQUEST_API_PATH, { action: "cancel", target: args.p_target });\n'
        '    case "remove_world_friend": return post(SOCIAL_FRIEND_REQUEST_API_PATH, { action: "remove", target: args.p_target });\n'
        '    case "block_world_user": return post(SOCIAL_BLOCK_API_PATH, { action: "block", target: args.p_target });\n'
        '    case "unblock_world_user": return post(SOCIAL_BLOCK_API_PATH, { action: "unblock", target: args.p_target });\n'
        '    case "report_world_user": return post(SOCIAL_REPORT_API_PATH, { target: args.p_target, category: args.p_category, placeZoneId: args.p_place_zone_id });\n'
        '    default: throw new Error(`unknown social RPC: ${name}`);\n'
        '  }\n'
        '}\n\n'
        'export const Relationship = Object.freeze({',
    ),
    (
        'const KNOWN_ERRORS = new Set(["NOT_ALLOWED", "TARGET_UNAVAILABLE", "PERMANENT_ACCOUNT_REQUIRED", "ACCOUNT_UNAVAILABLE",\n'
        '  "RATE_LIMITED", "CANNOT_REPORT_SELF", "INVALID_CATEGORY", "INVALID_PLACE_ZONE", "SOCIAL_RESTRICTED"]);',
        'const KNOWN_ERRORS = new Set(["NOT_ALLOWED", "TARGET_UNAVAILABLE", "PERMANENT_ACCOUNT_REQUIRED", "ACCOUNT_UNAVAILABLE",\n'
        '  "RATE_LIMITED", "CANNOT_REPORT_SELF", "INVALID_CATEGORY", "INVALID_PLACE_ZONE", "SOCIAL_RESTRICTED",\n'
        '  "PROFILE_NOT_FOUND"]);',
    ),
    (
        '  constructor({ getClient, getSelfUserId }) {\n'
        '    this.getClient = getClient;\n'
        '    this.getSelfUserId = getSelfUserId;',
        '  constructor({ getSessionId = readGuestSessionId, getSelfUserId, fetcher = (...args) => globalThis.fetch(...args) } = {}) {\n'
        '    this.getSessionId = getSessionId;\n'
        '    this.getSelfUserId = getSelfUserId;\n'
        '    this.fetcher = fetcher;',
    ),
    (
        '  get available() { return !!this.getClient() && isUserId(this.getSelfUserId()); }',
        '  get available() { return isUserId(this.getSelfUserId()); }',
    ),
    (
        '  async #rpc(name, args) {\n'
        '    const client = this.getClient();\n'
        '    const self = this.getSelfUserId();\n'
        '    if (!client || !isUserId(self)) throw new SocialError("SIGNED_OUT");\n'
        '    const generation = this.generation;\n'
        '    const { data, error } = await client.rpc(name, args);\n'
        '    if (generation !== this.generation || self !== this.getSelfUserId()) throw new SocialError("STALE");\n'
        '    if (error) {\n'
        '      const code = String(error.message ?? "").trim();\n'
        '      throw new SocialError(KNOWN_ERRORS.has(code) ? code : "FAILED");\n'
        '    }\n'
        '    return data;\n'
        '  }',
        '  async #rpc(name, args) {\n'
        '    const self = this.getSelfUserId();\n'
        '    if (!isUserId(self)) throw new SocialError("SIGNED_OUT");\n'
        '    let sessionId = null;\n'
        '    try { sessionId = await this.getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '    if (!sessionId) throw new SocialError("SIGNED_OUT");\n'
        '    const generation = this.generation;\n'
        '    const { path, init } = socialRequest(name, args ?? {}, sessionId);\n'
        '    let response;\n'
        '    try {\n'
        '      response = await this.fetcher(path, init);\n'
        '    } catch {\n'
        '      throw new SocialError("FAILED");\n'
        '    }\n'
        '    const data = await response.json().catch(() => null);\n'
        '    if (generation !== this.generation || self !== this.getSelfUserId()) throw new SocialError("STALE");\n'
        '    if (!response.ok) {\n'
        '      const code = typeof data?.error === "string" ? data.error.trim() : `HTTP_${response.status}`;\n'
        '      throw new SocialError(KNOWN_ERRORS.has(code) ? code : "FAILED");\n'
        '    }\n'
        '    return data;\n'
        '  }',
    ),
], "social-client.js")
write("social/social-client.js", SOCIAL)

# ---------------------------------------------------------------- accompany
ACCOMPANY_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — A-3): every path authenticates with the v0.1
// guest session id in the `X-Session-Id` header only — no other credential header is sent.
// The id is read lazily by readGuestSessionId() (the single source; null when absent — never
// fabricated). Read: GET /api/world-accompany. Mutations: POST /api/world-accompany
// { action: propose|respond|end, target?, poiId?, placeZoneId?, sessionId?, accept? }.
// The server answers 200 + the result, or an HTTP status with { error: <server refusal code> }.
// A missing profile answers 409 PROFILE_NOT_FOUND (added to ERRORS so the UI can show it).
// Before: the client called getClient().rpc() on the signed-in permanent-account client.
// That path is gone; only the transport changed — parsing and the error mapping are unchanged.
"""
ACCOMPANY = apply((SNAP / "social/accompany-client.js").read_text(), [
    (
        'import { isUserId, SocialError } from "./social-client.js";',
        'import { isUserId, SocialError } from "./social-client.js";\n'
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + ACCOMPANY_AUTH +
        'export const ACCOMPANY_API_PATH = "/api/world-accompany";\n\n'
        '// RPC name -> Tier 4 request (the Worker maps the action back to the RPC).\n'
        'function accompanyRequest(name, args, sessionId) {\n'
        '  const get = (path) => ({ path, init: { headers: { "X-Session-Id": sessionId } } });\n'
        '  const post = (body) => ({ path: ACCOMPANY_API_PATH, init: { method: "POST", headers: { "Content-Type": "application/json", "X-Session-Id": sessionId }, body: JSON.stringify(body) } });\n'
        '  switch (name) {\n'
        '    case "get_my_world_accompany": return get(ACCOMPANY_API_PATH);\n'
        '    case "propose_world_accompany": return post({ action: "propose", target: args.p_target, poiId: args.p_poi_id, placeZoneId: args.p_place_zone_id });\n'
        '    case "respond_world_accompany": return post({ action: "respond", sessionId: args.p_session_id, accept: args.p_accept });\n'
        '    case "end_world_accompany": return post({ action: "end", sessionId: args.p_session_id });\n'
        '    default: throw new Error(`unknown accompany RPC: ${name}`);\n'
        '  }\n'
        '}',
    ),
    (
        'const ERRORS = new Set(["NOT_ALLOWED", "ALREADY_BUSY", "RATE_LIMITED", "TARGET_UNAVAILABLE",\n'
        '  "INVALID_DESTINATION", "INVALID_PLACE_ZONE", "ACCOUNT_UNAVAILABLE", "PERMANENT_ACCOUNT_REQUIRED"]);',
        'const ERRORS = new Set(["NOT_ALLOWED", "ALREADY_BUSY", "RATE_LIMITED", "TARGET_UNAVAILABLE",\n'
        '  "INVALID_DESTINATION", "INVALID_PLACE_ZONE", "ACCOUNT_UNAVAILABLE", "PERMANENT_ACCOUNT_REQUIRED",\n'
        '  "PROFILE_NOT_FOUND"]);',
    ),
    (
        '  constructor({ getClient, getSelfUserId }) { Object.assign(this, { getClient, getSelfUserId }); }',
        '  constructor({ getSessionId = readGuestSessionId, getSelfUserId, fetcher = (...args) => globalThis.fetch(...args) } = {}) { Object.assign(this, { getSessionId, getSelfUserId, fetcher }); }',
    ),
    (
        '  async #rpc(name, args = {}) {\n'
        '    const client = this.getClient();\n'
        '    if (!client || !isUserId(this.getSelfUserId())) throw new SocialError("SIGNED_OUT");\n'
        '    const { data, error } = await client.rpc(name, args);\n'
        '    if (error) {\n'
        '      const code = String(error.message || "").trim();\n'
        '      throw new SocialError(ERRORS.has(code) ? code : "FAILED");\n'
        '    }\n'
        '    return data;\n'
        '  }',
        '  async #rpc(name, args = {}) {\n'
        '    if (!isUserId(this.getSelfUserId())) throw new SocialError("SIGNED_OUT");\n'
        '    let sessionId = null;\n'
        '    try { sessionId = await this.getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '    if (!sessionId) throw new SocialError("SIGNED_OUT");\n'
        '    const { path, init } = accompanyRequest(name, args, sessionId);\n'
        '    let response;\n'
        '    try {\n'
        '      response = await this.fetcher(path, init);\n'
        '    } catch {\n'
        '      throw new SocialError("FAILED");\n'
        '    }\n'
        '    const data = await response.json().catch(() => null);\n'
        '    if (!response.ok) {\n'
        '      const code = typeof data?.error === "string" ? data.error.trim() : `HTTP_${response.status}`;\n'
        '      throw new SocialError(ERRORS.has(code) ? code : "FAILED");\n'
        '    }\n'
        '    return data;\n'
        '  }',
    ),
], "accompany-client.js")
write("social/accompany-client.js", ACCOMPANY)

# ---------------------------------------------------------------- biryong sync
SYNC_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — A-3): both paths authenticate with the v0.1
// guest session id in the `X-Session-Id` header only — no other credential header is sent.
// The id is read lazily by readGuestSessionId() (the single source; null when absent — never
// fabricated). Read: GET /api/world-biryong-progress (null when the cloud copy does not exist
// yet). Merge: POST /api/world-biryong-progress { progress, migratedFromLocal }. The server
// answers 200 + the merged progress, or an HTTP status with { error: <server refusal code> }.
// Before: the controller called run.client.rpc() on the signed-in permanent-account client
// (get_my_biryong_progress_v1 / merge_my_biryong_progress_v1). That path is gone; only the
// transport changed — the debounce, generation guard, retry and merge rules are unchanged.
// The account bound by setAccount IS the guest session id.
"""
SYNC = apply((SNAP / "biryong/biryong-cloud-sync.js").read_text(), [
    (
        '// Biryong\'s local cache stays authoritative for unsent changes. The existing\n',
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + SYNC_AUTH +
        'export const BIRYONG_PROGRESS_API_PATH = "/api/world-biryong-progress";\n\n'
        '// Biryong\'s local cache stays authoritative for unsent changes. The existing\n',
    ),
    (
        'export function createBiryongCloudSync({\n'
        '  getClient,\n'
        '  progress,',
        'export function createBiryongCloudSync({\n'
        '  getSessionId = readGuestSessionId,\n'
        '  fetcher = (...args) => globalThis.fetch(...args),\n'
        '  endpoint = BIRYONG_PROGRESS_API_PATH,\n'
        '  progress,',
    ),
    (
        '  async function rpc(run, name, args) {\n'
        '    const { data, error } = await run.client.rpc(name, args);\n'
        '    if (error) throw error;\n'
        '    return data ?? null;\n'
        '  }',
        '  async function rpc(run, name, args) {\n'
        '    let sessionId = null;\n'
        '    try { sessionId = await getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '    if (!sessionId) throw new Error("SIGNED_OUT");\n'
        '    const isRead = name === \'get_my_biryong_progress_v1\';\n'
        '    const response = await fetcher(endpoint, isRead\n'
        '      ? { headers: { "X-Session-Id": sessionId } }\n'
        '      : { method: "POST", headers: { "Content-Type": "application/json", "X-Session-Id": sessionId }, body: JSON.stringify({ progress: args?.p_progress ?? null, migratedFromLocal: args?.p_migrated_from_local ?? false }) });\n'
        '    const data = await response.json().catch(() => null);\n'
        '    if (!response.ok) throw new Error(typeof data?.error === "string" && data.error ? data.error : `HTTP_${response.status}`);\n'
        '    return data ?? null;\n'
        '  }',
    ),
    (
        '  function setAccount(userId) {\n'
        '    if (disposed) return false;\n'
        '    const client = getClient?.() ?? null;\n'
        '    const next = userId && client ? userId : null;\n'
        '    if (next === (session?.userId ?? null) && (!next || client === session.client)) return false;',
        '  function setAccount(userId) {\n'
        '    if (disposed) return false;\n'
        '    const next = userId ? userId : null;\n'
        '    if (next === (session?.userId ?? null)) return false;',
    ),
    (
        '    session = { generation, userId: next, client, needsRead: true,',
        '    session = { generation, userId: next, needsRead: true,',
    ),
], "biryong-cloud-sync.js")
write("biryong/biryong-cloud-sync.js", SYNC)

# ---------------------------------------------------------------- biryong relationships
REL_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — A-3): the read authenticates with the v0.1
// guest session id in the `X-Session-Id` header only — no other credential header is sent.
// The id is read lazily by readGuestSessionId() (the single source; null when absent — never
// fabricated). Read: GET /api/world-biryong-npc-relationships. The server answers 200 + the
// 8-NPC list, or an HTTP status with { error: <server refusal code> }.
// Before: the client called getClient().rpc() on the signed-in permanent-account client
// (get_my_biryong_npc_relationships_v1). That path is gone; only the transport changed —
// parsing, state and generation are unchanged. This client stays read-only by design:
// the advance RPC (world_biryong_npc_relationship_advance_v1) has no client method here,
// exactly as in the original.
"""
REL = apply((SNAP / "biryong/biryong-village-relationship-client.js").read_text(), [
    (
        '// Biryong Village relationship read adapter.',
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + REL_AUTH +
        'export const BIRYONG_RELATIONSHIPS_API_PATH = "/api/world-biryong-npc-relationships";\n\n'
        '// Biryong Village relationship read adapter.',
    ),
    (
        'export function createBiryongRelationshipClient({\n'
        '  getClient = () => null,\n'
        '  getUserId = () => null\n'
        '} = {}) {',
        'export function createBiryongRelationshipClient({\n'
        '  getSessionId = readGuestSessionId,\n'
        '  getUserId = () => null,\n'
        '  fetcher = (...args) => globalThis.fetch(...args),\n'
        '  endpoint = BIRYONG_RELATIONSHIPS_API_PATH\n'
        '} = {}) {',
    ),
    (
        '        const client = getClient?.();\n'
        '        if (!client?.rpc) throw new Error("RELATIONSHIP_RPC_UNAVAILABLE");\n'
        '        const { data, error } = await client.rpc(BIRYONG_RELATIONSHIPS_RPC);\n'
        '        if (error) throw error;',
        '        let sessionId = null;\n'
        '        try { sessionId = await getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '        if (!sessionId) throw new Error("RELATIONSHIP_RPC_UNAVAILABLE");\n'
        '        const response = await fetcher(endpoint, { headers: { "X-Session-Id": sessionId } });\n'
        '        const data = await response.json().catch(() => null);\n'
        '        if (!response.ok) throw new Error(typeof data?.error === "string" && data.error ? data.error : `HTTP_${response.status}`);',
    ),
], "biryong-village-relationship-client.js")
write("biryong/biryong-village-relationship-client.js", REL)

# ---------------------------------------------------------------- MCM event client
MCM_AUTH = """
// AUTH (migrated 2026-11-20, Tier 4 guest-open — A-3): the live paths authenticate with the
// v0.1 guest session id in the `X-Session-Id` header only — no other credential header is
// sent. The id is read lazily by readGuestSessionId() (the single source; null when absent —
// never fabricated). Read: GET /api/world-mcm-event. Landlord run:
// POST /api/world-mcm-landlord-run (empty body). Landlord choice:
// POST /api/world-mcm-landlord-choice { runId, actorId }. Claims:
// POST /api/world-mcm-claim { claim: "main" | "landlord_first_clear" }.
// The server answers 200 + the result, or an HTTP status with { error: <server refusal code> }.
// Live advance is NOT available: advance_mcm_2026_event_v1 is server-only in Tier 4 (no HTTP
// endpoint, no client call in the original — the old /api/world-quest Bearer POST was the
// pre-Tier-4 quest path and is gone), so advance() throws MCM_ADVANCE_UNAVAILABLE outside
// preview. The preview branch still advances locally, unchanged.
// Before: refresh/startRun/submitRun/claim called getClient().rpc() on the signed-in
// permanent-account client. That path is gone; only the transport changed — the preview
// logic, server-offset tracking and boundary refresh are unchanged.
"""
MCM = apply((SNAP / "events/zombie-university-2026/event-client.js").read_text(), [
    (
        'import { MCM_2026_SCHEDULE, mcm2026ServerStateAt, resolveMcm2026Phase } from "./event-phase.js";',
        'import { MCM_2026_SCHEDULE, mcm2026ServerStateAt, resolveMcm2026Phase } from "./event-phase.js";\n'
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n' + MCM_AUTH +
        'export const MCM_EVENT_API_PATH = "/api/world-mcm-event";\n'
        'export const MCM_LANDLORD_RUN_API_PATH = "/api/world-mcm-landlord-run";\n'
        'export const MCM_LANDLORD_CHOICE_API_PATH = "/api/world-mcm-landlord-choice";\n'
        'export const MCM_CLAIM_API_PATH = "/api/world-mcm-claim";',
    ),
    (
        'const clone = value => value == null ? value : structuredClone(value);\n'
        'const rpcData = async promise => {\n'
        '  const {data,error}=await promise;\n'
        '  if(error) throw error;\n'
        '  return data;\n'
        '};',
        'const clone = value => value == null ? value : structuredClone(value);\n'
        '// Tier 4 fetch helper: X-Session-Id only, no Bearer. Throws MCM_AUTH_REQUIRED when\n'
        '// there is no session, the server refusal code on a non-2xx, or\n'
        '// MCM_PROGRESS_UNAVAILABLE when the server gives no code.\n'
        'async function fetchMcm(getSessionId, fetcher, path, init = {}) {\n'
        '  let sessionId = null;\n'
        '  try { sessionId = await getSessionId?.() ?? null; } catch { sessionId = null; }\n'
        '  if (!sessionId) throw Error("MCM_AUTH_REQUIRED");\n'
        '  const response = await fetcher(path, { ...init, headers: { ...(init.headers ?? {}), "X-Session-Id": sessionId } });\n'
        '  const data = await response.json().catch(() => null);\n'
        '  if (!response.ok) throw Error(typeof data?.error === "string" && data.error ? data.error : "MCM_PROGRESS_UNAVAILABLE");\n'
        '  return data;\n'
        '}',
    ),
    (
        'export function createMcm2026EventClient({\n'
        '  preview=false,\n'
        '  previewTimed=false,\n'
        '  endpoint="/api/world-quest",\n'
        '  getClient=()=>null,\n'
        '  getSessionToken=async()=>null,\n'
        '  fetcher=fetch,',
        'export function createMcm2026EventClient({\n'
        '  preview=false,\n'
        '  previewTimed=false,\n'
        '  getSessionId=readGuestSessionId,\n'
        '  fetcher=fetch,\n'
        '  mcmEndpoint=MCM_EVENT_API_PATH,\n'
        '  landlordRunEndpoint=MCM_LANDLORD_RUN_API_PATH,\n'
        '  landlordChoiceEndpoint=MCM_LANDLORD_CHOICE_API_PATH,\n'
        '  claimEndpoint=MCM_CLAIM_API_PATH,',
    ),
    (
        '    if(!signedIn)return null;\n'
        '    const client=getClient();\n'
        '    if(!client?.rpc)throw Error("MCM_CLIENT_UNAVAILABLE");\n'
        '    return applyServerState(await rpcData(client.rpc("get_my_mcm_2026_event_v1",{})));',
        '    if(!signedIn)return null;\n'
        '    return applyServerState(await fetchMcm(getSessionId,fetcher,mcmEndpoint));',
    ),
    (
        '    if(!signedIn||pending)return null;\n'
        '    const claim={};pending=claim;publish();\n'
        '    try{\n'
        '      const token=await getSessionToken();\n'
        '      if(!token)throw Error("MCM_AUTH_REQUIRED");\n'
        '      const response=await fetcher(endpoint,{\n'
        '        method:"POST",\n'
        '        headers:{"Content-Type":"application/json",Authorization:`Bearer ${token}`},\n'
        '        body:JSON.stringify({quest_id:MCM_2026_EVENT_ID,event:action})\n'
        '      });\n'
        '      if(!response.ok)throw Error("MCM_PROGRESS_UNAVAILABLE");\n'
        '      return applyServerState(await response.json());\n'
        '    }finally{if(pending===claim){pending=null;publish();}}',
        '    // A-3: advance_mcm_2026_event_v1 is server-only in Tier 4 (no HTTP endpoint and\n'
        '    // no client call in the original — the old /api/world-quest Bearer POST was the\n'
        '    // pre-Tier-4 quest path and is gone). The preview branch above still advances\n'
        '    // locally; a live advance is unavailable.\n'
        '    throw Error("MCM_ADVANCE_UNAVAILABLE");',
    ),
    (
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    const client=getClient();\n'
        '    const data=await rpcData(client.rpc("start_mcm_landlord_run_v1",{}));',
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    const data=await fetchMcm(getSessionId,fetcher,landlordRunEndpoint,{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"});',
    ),
    (
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    const client=getClient();\n'
        '    const data=await rpcData(client.rpc("submit_mcm_landlord_choice_v1",{p_run_id:runId,p_actor_id:actorId}));',
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    const data=await fetchMcm(getSessionId,fetcher,landlordChoiceEndpoint,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({runId,actorId})});',
    ),
    (
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    const client=getClient();\n'
        '    const fn=kind==="LANDLORD_FIRST_CLEAR"\n'
        '      ?"claim_my_mcm_landlord_first_clear_reward_v1":"claim_my_mcm_2026_main_reward_v1";\n'
        '    return rpcData(client.rpc(fn,{}));',
        '    if(!signedIn)throw Error("MCM_AUTH_REQUIRED");\n'
        '    return fetchMcm(getSessionId,fetcher,claimEndpoint,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({claim:kind==="LANDLORD_FIRST_CLEAR"?"landlord_first_clear":"main"})});',
    ),
], "event-client.js")
write("events/event-client.js", MCM)

# ---------------------------------------------------------------- verbatim MCM deps
for rel, src in [
    ("events/event-data.js", SNAP / "events/zombie-university-2026/event-data.js"),
    ("events/event-phase.js", SNAP / "events/zombie-university-2026/event-phase.js"),
    ("event-registry.js", SNAP / "events/event-registry.js"),
]:
    write(rel, src.read_text())

for rel in [
    "daily-quiz/daily-quiz-client.js",
    "life-skills/life-skill-book-client.js",
    "social/social-client.js",
    "social/accompany-client.js",
    "biryong/biryong-cloud-sync.js",
    "biryong/biryong-village-relationship-client.js",
    "events/event-client.js",
    "events/event-data.js",
    "events/event-phase.js",
    "event-registry.js",
]:
    node_check(rel)

print("all A-3 clients generated and syntax-checked")
