// INHA WORLD — fishing position reporter (REFERENCE MODULE, NOT WIRED).
//
// Sends the local player's position to POST /api/fishing-position every 2 s while
// the fishing panel is open, so the F3 cast / HOOK gate has fresh evidence.
// Nothing imports this file yet; it is meant to be copied into the world client
// (aldol2678/inhagame apps/world) when the guest-open fishing path is connected.
//
// This is a CLIENT-REPORTED position. The server cannot verify it and a modified
// client can report any position. It is not the trusted, server-derived evidence
// the original F3 design described. The server still refuses stale (>= 5 s),
// replayed, out-of-range and backwards-revision reports.
//
// Where the inputs come from in the real world client (read-only references; this
// module does not import them, so it carries no dependency on their shape):
//   - Position: src/online/pose-source.js `createPoseSource({ player, controller,
//     isSeated }).sample(dt).pose` gives { x, y, z, anim, mount } in the
//     CampusCoordinateFrame local frame — the same frame as the server's spot
//     geometry and src/activity/fishing-spots.js.
//   - Open / close: src/activity/fishing-panel.js `createFishingPanel({ onOpenChange })`
//     calls onOpenChange(true / false). Call reporter.start() / reporter.stop() there.
//   - State: map pose.mount (non-null = mounted), pose.anim (SIT, AIR, FLY) plus the
//     client's own indoor / combat / connection flags into getState() below.
//
// Usage:
//   const reporter = createPositionReporter({
//     getSessionId: () => syncSession.id,           // the v0.1 server-issued session id
//     getPose: () => ({ x, y, z }),                 // CampusCoordinateFrame local, or null
//     getState: () => ({ indoor, mounted, seated, combat, airborne, disconnected }),
//   });
//   fishingPanel onOpenChange: open ? reporter.start() : reporter.stop();

export const POSITION_ENDPOINT = '/api/fishing-position';
export const REPORT_INTERVAL_MS = 2000;
const REVISION_KEY_PREFIX = 'inha-world:fishing-position-revision:';

/**
 * Eligible only when walking outdoors on campus. Anything else — indoors, mounted,
 * seated, in combat, airborne, disconnected, or an unknown state — is OTHER /
 * INELIGIBLE, which the server accepts as evidence but never lets cast or HOOK.
 */
export function classifyPositionState(state) {
  const flags = state ?? {};
  const ineligible = ['indoor', 'mounted', 'seated', 'combat', 'airborne', 'disconnected']
    .some((key) => flags[key] !== false);
  return ineligible ? { space: 'OTHER', mode: 'INELIGIBLE' } : { space: 'CAMPUS', mode: 'ON_FOOT' };
}

/**
 * One strictly increasing revision per session, kept in sessionStorage so a page
 * reload continues the sequence instead of restarting at 1 (which the server
 * would answer with STALE).
 */
export function createRevisionCounter({ storage = globalThis.sessionStorage, sessionId }) {
  const key = REVISION_KEY_PREFIX + sessionId;
  const read = () => {
    try {
      const value = Number(storage?.getItem(key));
      return Number.isSafeInteger(value) && value > 0 ? value : 0;
    } catch {
      return 0;
    }
  };
  let current = read();
  const write = (value) => {
    current = value;
    try { storage?.setItem(key, String(value)); } catch { /* storage full or blocked: keep the in-memory value */ }
  };
  return {
    current: () => current,
    /** The revision to send next. */
    next() {
      write(Math.max(current, read()) + 1);
      return current;
    },
    /** The server holds a newer revision: continue after it. */
    advanceTo(revision) {
      if (Number.isSafeInteger(revision) && revision > current) write(revision);
    },
  };
}

export function createPositionReporter({
  getSessionId,
  getPose,
  getState,
  fetch: fetcher = globalThis.fetch?.bind(globalThis),
  storage = globalThis.sessionStorage,
  setInterval: every = globalThis.setInterval?.bind(globalThis),
  clearInterval: cancel = globalThis.clearInterval?.bind(globalThis),
  logger = globalThis.console,
  endpoint = POSITION_ENDPOINT,
  intervalMs = REPORT_INTERVAL_MS,
} = {}) {
  let timer = null;
  let inFlight = false;
  let stopped = true;
  let counter = null;
  let counterSession = null;

  function revisions(sessionId) {
    if (counterSession !== sessionId) {
      counter = createRevisionCounter({ storage, sessionId });
      counterSession = sessionId;
    }
    return counter;
  }

  async function tick() {
    // Never overlap: a slow request must not be overtaken by a newer revision.
    if (stopped || inFlight) return 'skipped';
    const sessionId = getSessionId?.();
    const pose = getPose?.();
    if (!sessionId || !pose || ![pose.x, pose.y, pose.z].every(Number.isFinite)) return 'skipped';
    const counterForSession = revisions(sessionId);
    const body = { revision: counterForSession.next(), x: pose.x, y: pose.y, z: pose.z, ...classifyPositionState(getState?.()) };
    inFlight = true;
    try {
      const response = await fetcher(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Session-Id': sessionId },
        body: JSON.stringify(body),
      });
      if (response.status === 401) {
        // No session the server knows: stop instead of retrying every 2 s.
        logger?.warn?.('fishing position reporter stopped: session not recognised (401)');
        stop();
        return 'unauthenticated';
      }
      if (response.status === 429) return 'rate-limited'; // try again on the next tick
      if (response.status === 409) {
        // This revision was already used with a different payload (e.g. another tab):
        // the next tick uses a fresh one.
        return 'conflict';
      }
      if (response.ok) {
        const result = await response.json().catch(() => null);
        if (result?.status === 'STALE') counterForSession.advanceTo(result.revision);
        return result?.status ?? 'ok';
      }
      return 'failed';
    } catch {
      return 'failed'; // network error: the next tick retries with a newer revision
    } finally {
      inFlight = false;
    }
  }

  function start() {
    if (!stopped) return;
    stopped = false;
    tick();
    timer = every(tick, intervalMs);
  }

  function stop() {
    stopped = true;
    if (timer !== null) cancel(timer);
    timer = null;
  }

  return { start, stop, tick, isRunning: () => !stopped };
}
