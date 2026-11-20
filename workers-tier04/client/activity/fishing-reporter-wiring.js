// INHA WORLD — fishing position reporter wiring.
//
// Patch for the world client (aldol2678/inhagame apps/world; snapshot:
// ~/workspace/inha-world-static-test/src/main.js, fishingPanel at main.js:1767).
// NOT applied to any client yet. Apply main.js.patch to a COPY of the client,
// never to the snapshot or the read-only inhagame clone.
//
// WARNING — client-reported position, NOT trusted evidence. The original F3
// design accepts position evidence only from an authoritative world server and
// states that browser poses are not evidence; no such server exists. This feed
// relays what the browser says, so a modified client can claim to stand on a
// fishing spot. It is a deliberate, guest-friendly trade-off (decision
// 2026-11-12, Tier 3 README "낚시 위치 피드"). What still holds is everything
// inside world_fishing_observe_position_v1 and the cast/HOOK gates: one
// strictly increasing revision per session, evidence older than 5 s refused,
// bounded coordinates, a 3-unit radius and y between -1 and 4 at the spot, one
// lease per bank. Replays, stale and out-of-range positions are filtered out.
//
// Design notes (all reads are lazy per-tick callbacks — nothing is captured):
// - `rooms` is still null where the panel is created (main.js:959 declares it,
//   main.js:2102 assigns it) and `online` is assigned even later (main.js:4009).
//   The reporter calls getSessionId / getPose / getState on every tick, so by
//   the time the panel opens both exist. Do NOT capture their values at attach.
// - getPose does NOT use poseSource.sample(dt): poseSource is encapsulated
//   inside startWorldOnline (world-online.js:49) and room-session.js:56 and is
//   not exposed to main.js scope. player.getLocalPosition() is the same call
//   pose-source.js makes, on the same CampusCoordinateFrame local frame, so
//   {x, y, z} are identical. anim/mount are derived from controller/seats with
//   the same rules as classifyAnim (network/protocol.js:289-295).
// - getSessionId: the static-test snapshot has NO v0.1 session id at all — it
//   authenticates with Supabase (online.userId + access token, main.js:1735).
//   The v0.1 guest session id is issued by the sync Worker (POST
//   <sync-worker>/api/session) and stored by FutureSyncAdapter
//   (rebuild-v01/src/api.js:127-143) under 'inha-v01:sync-session'. The host
//   client must supply it via getSessionId; the default below only reads the
//   key that adapter wrote. A missing session makes the reporter skip ticks —
//   it NEVER fabricates an id.
// - fishing-client.js still authenticates with `Authorization: Bearer <Supabase
//   token>`; the Tier 3 Worker expects `X-Session-Id` instead. That migration
//   is NOT part of this patch — see README.md "남은 것". The e2e harness drives
//   the same /api/world-fishing endpoints with X-Session-Id the way a migrated
//   fishing client will.

import { createPositionReporter } from './fishing-position-reporter.js';

export const POSITION_ENDPOINT = '/api/fishing-position';
export const SYNC_SESSION_STORAGE_KEY = 'inha-v01:sync-session';
export const SERVER_SESSION_STORAGE_KEY = 'inha-v01:server-session';

/**
 * Read the v0.1 guest session id the sync adapter stored. Sync key first
 * (FutureSyncAdapter), local-server key second (ServerAdapter). Returns null
 * when neither exists — never fabricates an id.
 */
export function readGuestSessionId(storage = globalThis.localStorage) {
  for (const key of [SYNC_SESSION_STORAGE_KEY, SERVER_SESSION_STORAGE_KEY]) {
    try {
      const value = storage?.getItem?.(key);
      if (typeof value === 'string' && value.length > 0) return value;
    } catch { /* storage blocked: treat as no session */ }
  }
  return null;
}

/**
 * Build the reporter's three inputs from objects main.js already has in scope.
 * Every read is lazy: called on each 2 s tick, never at attach time.
 *
 * State mapping (authority: classifyAnim, network/protocol.js:289-295, where
 * seated -> 'sit', mounted -> 'fly', !grounded -> 'air'):
 * - indoor:    rooms.insideRoom (main.js:1745, 1816)
 * - mounted:   controller.mounted (pose-source.js: mounted = controller.mounted
 *              === true; classifyAnim mounted -> 'fly')
 * - seated:    seats.isSeated, a boolean property (main.js:995, 1816;
 *              classifyAnim seated -> 'sit')
 * - airborne:  !grounded && !mounted && !seated (classifyAnim !grounded ->
 *              'air'; swimming is not distinguished by anim — the server's
 *              spot-radius / y-range checks still apply)
 * - combat:    combatRuntime.active (main.js:1505, water-path getContext)
 * - disconnected: no v0.1 session id, unless isConnected is supplied. (The
 *   Supabase `online` session is NOT used here: it is a different identity
 *   from the v0.1 guest session this feed authenticates with.)
 */
export function buildFishingPositionInputs({
  player, controller, seats, rooms, combatRuntime, getSessionId, isConnected,
} = {}) {
  const readSession = typeof getSessionId === 'function'
    ? getSessionId
    : () => readGuestSessionId();
  return {
    getSessionId: () => readSession() ?? null,
    getPose: () => {
      const p = player?.getLocalPosition?.();
      if (!p || ![p.x, p.y, p.z].every(Number.isFinite)) return null;
      return { x: p.x, y: p.y, z: p.z };
    },
    getState: () => {
      const mounted = controller?.mounted === true;
      const seated = seats?.isSeated === true;
      const grounded = controller?.grounded !== false;
      return {
        indoor: rooms?.insideRoom === true,
        mounted,
        seated,
        combat: combatRuntime?.active === true,
        airborne: !grounded && !mounted && !seated,
        disconnected: typeof isConnected === 'function'
          ? isConnected() !== true
          : readSession() == null,
      };
    },
  };
}

/**
 * Attach the reporter. Returns { reporter, getSessionId, getPose, getState }.
 * The caller starts/stops it from the fishing panel's onOpenChange (see
 * main.js.patch). `apiBase` is for isolated testing only: when set, the feed
 * goes to `${apiBase}/api/fishing-position` (e.g. the tier03-test Worker
 * origin); otherwise the relative '/api/fishing-position' is used, so the feed
 * stays same-host with the page that serves the client.
 */
export function attachFishingPositionReporter({
  player, controller, seats, rooms, combatRuntime, getSessionId, isConnected,
  apiBase, endpoint, fetch, storage, setInterval, clearInterval, logger,
} = {}) {
  const inputs = buildFishingPositionInputs({
    player, controller, seats, rooms, combatRuntime, getSessionId, isConnected,
  });
  const resolvedEndpoint = endpoint
    ?? (typeof apiBase === 'string' && apiBase.length > 0
      ? `${apiBase.replace(/\/$/, '')}${POSITION_ENDPOINT}`
      : POSITION_ENDPOINT);
  const reporter = createPositionReporter({
    ...inputs,
    endpoint: resolvedEndpoint,
    ...(fetch !== undefined ? { fetch } : {}),
    ...(storage !== undefined ? { storage } : {}),
    ...(setInterval !== undefined ? { setInterval } : {}),
    ...(clearInterval !== undefined ? { clearInterval } : {}),
    ...(logger !== undefined ? { logger } : {}),
  });
  return { reporter, ...inputs };
}
