# INHA WORLD — Tier 0+1 Cloudflare Worker (isolated test)

Faithful port of the Vercel handlers in `apps/world/api/*.js`
(aldol2678/inhagame HEAD `0b72d259`) to the Workers Fetch API.
Source repo was read-only; nothing in the clone or any live project was touched.

## What is ported

| Route | Source | Behaviour |
|---|---|---|
| `GET /api/world-time` | `api/world-time.js` + `npc-world-time-contract.mjs` | Pure function, no env. Returns `{revision, serverNowMs, epochMs, periodMs, periods}`. Non-GET → 405. |
| `GET /api/public-supabase-config` | `api/public-supabase-config.js` | Reads `SUPABASE_URL` + `SUPABASE_PUBLISHABLE_KEY` from Worker env. Valid → 200 JS `globalThis.__INHAGAME_PUBLIC_SUPABASE__ = Object.freeze({...});`. Invalid/unset → 503 JS `console.error('INHAGAME public Supabase config is unavailable');`. Non-GET → 405. |
| `GET/POST /api/npc-ai` | `api/npc-ai.js` | Thin proxy to `NPC_AI_CLOUD_RUN_URL` (`/`). GET probe → `{enabled:true}` or 404 when unconfigured. POST: JSON content-type, same-host Origin, Bearer token, 2048-byte body limit, 25s upstream timeout, upstream status+JSON proxied, fetch failure → 503 `{error:'NPC_AI_UNAVAILABLE'}`. |
| `GET/POST /api/npc-relationship` | `api/npc-relationship.js` | Same pattern, upstream path `/relationship`, flag `NPC_RELATIONSHIP_ENABLED`, 256-byte body limit, body must be exactly `{npcId, event}` strings, 10s timeout, failure → 503 `{error:'NPC_RELATIONSHIP_UNAVAILABLE'}`. |
| `GET/POST /api/world-quest` | `api/world-quest.js` | Same pattern, upstream path `/quest`, flag `NPC_QUEST_ENABLED`, 256-byte body limit, body must be `{event}` plus optional `quest_id`, 10s timeout, failure → 503 `{error:'QUEST_UNAVAILABLE'}`. |

Guard order matches the originals: enabled-check first (404), then GET probe,
then content-type (405), Origin (403), Bearer (401), body size (413), JSON/shape (400).

## Test deployment

- **URL:** https://inha-world-tier01-test.aldol-lab.workers.dev
- **Worker name:** `inha-world-tier01-test` (new, isolated; no live project touched)
- **Deployed:** 2026-11-11, wrangler 4.158.0 via the Cloudflare API-token helper
- **Env:** intentionally UNSET — no real URLs, keys, or tokens anywhere in this
  directory, the deploy, or the logs.

## Verification (2026-11-11, curl, live)

| Check | Result | What it proves |
|---|---|---|
| `GET /api/world-time` | **200** `{"revision":"ng2-campus-life-v3","serverNowMs":1794377592699,"epochMs":1767225600000,"periodMs":900000,"periods":["morning","class_time","lunch","evening","night"]}` + `Cache-Control: no-store, max-age=0` | Time payload matches the source contract exactly (epoch = Date.UTC(2026,0,1), 15-min periods); no-store headers preserved. |
| `GET /api/public-supabase-config` | **503** `console.error('INHAGAME public Supabase config is unavailable');` | Unconfigured path reproduces the Vercel handler's 503 JS body byte-for-byte. |
| `GET /api/npc-ai` | **404** | Disabled when `NPC_AI_ENABLED`/`NPC_AI_CLOUD_RUN_URL` are unset, as in the original. |
| `GET /api/npc-relationship` | **404** | Same, flag `NPC_RELATIONSHIP_ENABLED`. |
| `GET /api/world-quest` | **404** | Same, flag `NPC_QUEST_ENABLED`. |
| `POST /api/npc-ai` (no auth) | **404** | Enabled-check precedes auth, matching the original order. |
| `GET /api/nope` | **404** | Unknown routes 404. |

## What still needs real env values before any production use

Set these only via the Cloudflare dashboard or `wrangler secret put`, from the
real deployment config — never commit values here:

- `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` — enables `public-supabase-config`
  to serve the real JS config instead of the 503 body. (Publishable key only;
  no service-role key is used by any Tier 0+1 handler.)
- `NPC_AI_CLOUD_RUN_URL` (real Cloud Run base URL) + `NPC_AI_ENABLED=1` /
  `NPC_RELATIONSHIP_ENABLED=1` / `NPC_QUEST_ENABLED=1` — enables the three NPC
  proxies. The Cloud Run backend itself stays as-is; the Worker only forwards.
- With those set, re-verify: GET probes should return `{enabled:true}`, and a
  POST with a valid Bearer token should proxy to Cloud Run and return its
  status + JSON. Without them, the handlers stay safely disabled (404/503),
  which is also exactly how the guest-mode static test treats them.

## Out of scope (later tiers)

Tier 2 (hub-entry, hub-event, asset-canary-flag) and Tier 3 (world-fishing,
world-collection-book, Auth, ranked, mail verify) need the Neon data layer
first; Tier 4 (brand-asset, brand-induck, brand-media) needs the 3 missing
brand Edge Functions located. See `../api-inventory-2026-11-11.md`.
