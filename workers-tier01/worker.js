// INHA WORLD — Tier 0+1 Cloudflare Worker port (isolated test).
// Faithful port of the Vercel handlers in apps/world/api/*.js
// (aldol2678/inhagame HEAD 0b72d259) to the Workers Fetch API.
// No real secrets: env vars are intentionally UNSET in this test deploy,
// so the handlers run in their disabled/unconfigured paths (404 / 503).
// See README.md for what still needs real env values before production use.

// ---- world-time: pure function (npc-factory/npc-world-time-contract.mjs) ----
const NPC_SCHEDULE_REVISION = 'ng2-campus-life-v3';
const NPC_WORLD_EPOCH_MS = Date.UTC(2026, 0, 1);
const NPC_WORLD_PERIOD_MS = 15 * 60_000;
const NPC_WORLD_PERIODS = Object.freeze(['morning', 'class_time', 'lunch', 'evening', 'night']);

function worldTimePayload(serverNowMs = Date.now()) {
  return {
    revision: NPC_SCHEDULE_REVISION,
    serverNowMs,
    epochMs: NPC_WORLD_EPOCH_MS,
    periodMs: NPC_WORLD_PERIOD_MS,
    periods: [...NPC_WORLD_PERIODS],
  };
}

function handleWorldTime(request) {
  const headers = new Headers({
    'Cache-Control': 'no-store, max-age=0',
    'CDN-Cache-Control': 'no-store',
    'Vercel-CDN-Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
  });
  if (request.method !== 'GET') {
    headers.set('Allow', 'GET');
    return new Response(null, { status: 405, headers });
  }
  return new Response(JSON.stringify(worldTimePayload()), { status: 200, headers });
}

// ---- public-supabase-config: GET returns JS, or 503 JS when unconfigured ----
function publicConfig(env) {
  const url = String(env.SUPABASE_URL || '').trim();
  const publishableKey = String(env.SUPABASE_PUBLISHABLE_KEY || '').trim();
  const validUrl = /^https:\/\/[a-z0-9.-]+(?::[0-9]+)?(?:\/.*)?$/i.test(url);
  const validKey = publishableKey.startsWith('sb_publishable_');
  return validUrl && validKey ? { url, publishableKey } : null;
}

function handlePublicSupabaseConfig(request, env) {
  const headers = new Headers({ 'Content-Type': 'application/javascript; charset=utf-8' });
  if (request.method !== 'GET') {
    headers.set('Cache-Control', 'no-store, max-age=0');
    headers.set('Allow', 'GET');
    return new Response(null, { status: 405, headers });
  }
  const config = publicConfig(env);
  if (!config) {
    headers.set('Cache-Control', 'no-store, max-age=0');
    return new Response(
      "console.error('INHAGAME public Supabase config is unavailable');",
      { status: 503, headers },
    );
  }
  // Only browser-safe values (URL + publishable key); cache at the edge.
  headers.set('Cache-Control', 'public, max-age=60, s-maxage=300, stale-while-revalidate=86400');
  return new Response(
    'globalThis.__INHAGAME_PUBLIC_SUPABASE__ = Object.freeze(' +
      JSON.stringify(config) + ');',
    { status: 200, headers },
  );
}

// ---- NPC proxies: npc-ai, npc-relationship, world-quest ----
// Same guards as the Vercel originals: enabled flag + https upstream URL,
// GET probe, POST requires JSON content-type, same-host Origin, Bearer token,
// body size limits, shape validation, upstream fetch with timeout.
const BEARER_RE = /^Bearer [A-Za-z0-9._~-]{20,4096}$/u;

function sameHostOrigin(request) {
  const origin = request.headers.get('origin');
  if (!origin) return true;
  try {
    return new URL(origin).host === request.headers.get('host');
  } catch {
    return false;
  }
}

async function handleNpcProxy(request, env, spec) {
  const headers = new Headers({
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
  });
  const configuredUrl = env.NPC_AI_CLOUD_RUN_URL;
  const enabled =
    env[spec.enabledFlag] === '1' && /^https:\/\//u.test(configuredUrl ?? '');
  if (!enabled) return new Response(null, { status: 404, headers });
  if (request.method === 'GET') {
    return new Response(JSON.stringify({ enabled: true }), { status: 200, headers });
  }
  const contentType = request.headers.get('content-type')?.split(';')[0];
  if (request.method !== 'POST' || contentType !== 'application/json') {
    return new Response(null, { status: 405, headers });
  }
  if (!sameHostOrigin(request)) return new Response(null, { status: 403, headers });
  if (!BEARER_RE.test(request.headers.get('authorization') ?? '')) {
    return new Response(null, { status: 401, headers });
  }
  const raw = await request.text();
  if (raw.length > spec.maxBodyBytes) return new Response(null, { status: 413, headers });
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response(null, { status: 400, headers });
  }
  if (!spec.isValidBody(body)) return new Response(null, { status: 400, headers });
  const upstreamUrl =
    spec.pathSuffix === ''
      ? configuredUrl
      : `${configuredUrl.replace(/\/$/u, '')}${spec.pathSuffix}`;
  try {
    const response = await fetch(upstreamUrl, {
      method: 'POST',
      signal: AbortSignal.timeout(spec.timeoutMs),
      headers: {
        'Content-Type': 'application/json',
        Authorization: request.headers.get('authorization'),
      },
      body: JSON.stringify(body),
    });
    const result = await response.json();
    return new Response(JSON.stringify(result), { status: response.status, headers });
  } catch {
    return new Response(JSON.stringify({ error: spec.unavailableError }), {
      status: 503,
      headers,
    });
  }
}

const NPC_SPECS = {
  '/api/npc-ai': {
    enabledFlag: 'NPC_AI_ENABLED',
    pathSuffix: '',
    timeoutMs: 25000,
    maxBodyBytes: 2048,
    unavailableError: 'NPC_AI_UNAVAILABLE',
    isValidBody: (body) =>
      Boolean(body) &&
      typeof body === 'object' &&
      !Array.isArray(body) &&
      JSON.stringify(body).length <= 2048,
  },
  '/api/npc-relationship': {
    enabledFlag: 'NPC_RELATIONSHIP_ENABLED',
    pathSuffix: '/relationship',
    timeoutMs: 10000,
    maxBodyBytes: 256,
    unavailableError: 'NPC_RELATIONSHIP_UNAVAILABLE',
    isValidBody: (body) =>
      Boolean(body) &&
      typeof body === 'object' &&
      !Array.isArray(body) &&
      Object.keys(body).length === 2 &&
      typeof body.npcId === 'string' &&
      typeof body.event === 'string' &&
      JSON.stringify(body).length <= 256,
  },
  '/api/world-quest': {
    enabledFlag: 'NPC_QUEST_ENABLED',
    pathSuffix: '/quest',
    timeoutMs: 10000,
    maxBodyBytes: 256,
    unavailableError: 'QUEST_UNAVAILABLE',
    isValidBody: (body) =>
      Boolean(body) &&
      typeof body === 'object' &&
      !Array.isArray(body) &&
      [1, 2].includes(Object.keys(body).length) &&
      typeof body.event === 'string' &&
      (body.quest_id == null || typeof body.quest_id === 'string') &&
      JSON.stringify(body).length <= 256,
  },
};

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === '/api/world-time') return handleWorldTime(request);
    if (pathname === '/api/public-supabase-config') {
      return handlePublicSupabaseConfig(request, env);
    }
    if (pathname in NPC_SPECS) return handleNpcProxy(request, env, NPC_SPECS[pathname]);
    return new Response('Not found', { status: 404 });
  },
};
