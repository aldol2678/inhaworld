// INHA WORLD — Tier 2 telemetry Cloudflare Worker (isolated test).
// Port of the Vercel handlers apps/world/api/hub-entry.js, hub-event.js and
// asset-canary-flag.js (aldol2678/inhagame HEAD 0b72d259) from
// Vercel + Supabase REST to the Workers Fetch API + Neon.
// Status codes, guard order and headers follow the originals; the Supabase
// RPCs live in schema.sql as log_game_entry_v1 / log_hub_event_v2.
// DATABASE_URL comes from `wrangler secret put DATABASE_URL` only — never from
// a file, [vars], or a log line.
import { neon } from '@neondatabase/serverless';

// One HTTP query per request, with the same upstream timeout as the original
// fetch (4000 ms for the two loggers, 1200 ms for the flag).
function connect(env, timeoutMs) {
  return neon(env.DATABASE_URL, {
    fetchOptions: { signal: AbortSignal.timeout(timeoutMs) },
  });
}

// Original mapping: Supabase answered with a non-2xx -> 502; the fetch itself
// failed (unreachable, timeout, unreadable reply) -> 503. With Neon over HTTP,
// "answered with an error" is a NeonDbError that has no sourceError; anything
// else (no connection string, network failure, timeout) is the 503 path.
function upstreamFailureStatus(error) {
  return error?.name === 'NeonDbError' && !error.sourceError ? 502 : 503;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// ---- hub-entry: game funnel stages, called cross-origin by the games ----
const ENTRY_ORIGINS = {
  'https://inhagame.app': 'campus',
  'https://duck.inhagame.app': 'classic',
  'https://induckup.inhagame.app': 'induckup',
  'https://survival.inhagame.app': 'survival',
  'https://grow.inhagame.app': 'induck-grow',
};
const ENTRY_EVENTS = new Set(['game_landing', 'game_play_start', 'game_load_error',
  'game_first_result', 'game_first_clear', 'game_retry', 'classic_ranked_start']);

async function handleHubEntry(request, env) {
  const headers = new Headers({ 'Cache-Control': 'no-store' });
  const origin = request.headers.get('origin');
  const target = origin !== null && Object.hasOwn(ENTRY_ORIGINS, origin)
    ? ENTRY_ORIGINS[origin]
    : undefined;
  if (!target) return new Response(null, { status: 403, headers });
  headers.set('Access-Control-Allow-Origin', origin);
  headers.set('Vary', 'Origin');
  headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  headers.set('Access-Control-Allow-Headers', 'Content-Type');
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return new Response(null, { status: 405, headers });
  const raw = await request.text();
  if (raw.length > 512) return new Response(null, { status: 413, headers });
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response(null, { status: 400, headers });
  }
  if (!body || typeof body !== 'object' || !UUID.test(body.event_id) ||
      !UUID.test(body.entry_id) || !ENTRY_EVENTS.has(body.event_type) || body.target !== target) {
    return new Response(null, { status: 400, headers });
  }
  try {
    const sql = connect(env, 4000);
    // The target stored is the one derived from the Origin, never the body's.
    const rows = await sql`select public.log_game_entry_v1(${body.event_id}::uuid, ${body.entry_id}::uuid, ${body.event_type}::text, ${target}::text) as accepted`;
    // true: stored, or an idempotent resend. false: refused (no fresh hub
    // click, or the previous stage is not stored yet) — the client retries 409.
    return new Response(null, { status: rows[0]?.accepted === true ? 204 : 409, headers });
  } catch (error) {
    return new Response(null, { status: upstreamFailureStatus(error), headers });
  }
}

// ---- hub-event: hub / campus telemetry, same-origin (beacon or fetch) ----
const HUB_SOURCES = new Set(['direct', 'everytime', 'internal', 'external', 'unknown']);
const HUB_CAMPAIGN = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const HUB_EVENTS = new Set([
  'hub_visit', 'hub_panel_view', 'hub_game_click', 'campus_entry_click',
  'campus_boot_ready', 'campus_boot_error', 'campus_zone_enter', 'hub_card_impression',
  'profile_view', 'profile_edit_open', 'profile_edit_save', 'profile_game_click',
  'first_session_start', 'first_goal_seen', 'first_move', 'first_zone_arrival', 'first_npc_interaction',
  'quest_started', 'first_player_encounter', 'first_activity_start', 'first_activity_complete',
  'first_reward', 'reward_seen', 'growth_seen', 'core_loop_complete', 'next_goal_seen',
  'core15_complete', 'world_return', 'next_discovery_click',
  'asset_canary_selected', 'asset_canary_active', 'asset_canary_rollback', 'asset_canary_failure',
]);

async function handleHubEvent(request, env) {
  const headers = new Headers({ 'Cache-Control': 'no-store' });
  if (request.method !== 'POST') return new Response(null, { status: 405, headers });
  const origin = request.headers.get('origin');
  const host = request.headers.get('host');
  if (origin) {
    try {
      if (!host || new URL(origin).host !== host) {
        return new Response(null, { status: 403, headers });
      }
    } catch {
      return new Response(null, { status: 403, headers });
    }
  }
  const raw = await request.text();
  if (raw.length > 1024) return new Response(null, { status: 413, headers });
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response(null, { status: 400, headers });
  }
  const acquisitionSource = body?.acquisition_source == null
    ? 'unknown'
    : HUB_SOURCES.has(body.acquisition_source) ? body.acquisition_source : null;
  if (!body || typeof body !== 'object' || !UUID.test(body.event_id) ||
      !UUID.test(body.session_id) || !UUID.test(body.visitor_id) ||
      !HUB_EVENTS.has(body.event_type) || typeof body.surface !== 'string' ||
      (body.target !== null && body.target !== undefined && typeof body.target !== 'string') ||
      !acquisitionSource ||
      (body.campaign !== null && body.campaign !== undefined &&
        (typeof body.campaign !== 'string' || !HUB_CAMPAIGN.test(body.campaign)))) {
    return new Response(null, { status: 400, headers });
  }
  try {
    const sql = connect(env, 4000);
    const rows = await sql`select public.log_hub_event_v2(${body.event_id}::uuid, ${body.session_id}::uuid, ${body.visitor_id}::uuid, ${body.event_type}::text, ${body.surface}::text, ${body.target ?? null}::text, ${acquisitionSource}::text, ${body.campaign ?? null}::text) as accepted`;
    return new Response(null, { status: rows[0]?.accepted === true ? 204 : 400, headers });
  } catch (error) {
    return new Response(null, { status: upstreamFailureStatus(error), headers });
  }
}

// ---- asset-canary-flag: remote kill switch, fails closed (503 = canary off) ----
const CANARY_FLAG = 'asset_glb_canary_v1';

async function handleAssetCanaryFlag(request, env) {
  const headers = new Headers({
    'Cache-Control': 'no-store, max-age=0',
    'Vercel-CDN-Cache-Control': 'public, s-maxage=5, stale-while-revalidate=5',
  });
  if (request.method !== 'GET') {
    headers.set('Allow', 'GET');
    return new Response(null, { status: 405, headers });
  }
  try {
    const sql = connect(env, 1200);
    const rows = await sql`select enabled from public.runtime_flags where flag = ${CANARY_FLAG} limit 1`;
    if (!Array.isArray(rows) || rows.length !== 1 || typeof rows[0]?.enabled !== 'boolean') {
      return new Response(null, { status: 503, headers });
    }
    headers.set('Content-Type', 'application/json; charset=utf-8');
    return new Response(JSON.stringify({ enabled: rows[0].enabled === true }), {
      status: 200,
      headers,
    });
  } catch {
    return new Response(null, { status: 503, headers });
  }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === '/api/hub-entry') return handleHubEntry(request, env);
    if (pathname === '/api/hub-event') return handleHubEvent(request, env);
    if (pathname === '/api/asset-canary-flag') return handleAssetCanaryFlag(request, env);
    return new Response('Not found', { status: 404 });
  },
};
