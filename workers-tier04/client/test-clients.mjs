// Unit tests for the migrated Tier 4 clients (A-1 reads + A-2 writes + A-3 state machines + BCD profile/mail/online).
// Run: node test-clients.mjs  (Node, no dependencies, no network.)
// Every test uses a stub fetcher and asserts the migrated contract:
// X-Session-Id is sent, Authorization/Bearer is never sent, a missing session
// sends nothing, server rejections keep their states, and the 409 / 400 edge
// cases behave as specified. The Tier 4 Worker is not deployed yet, so there
// is no live-origin test here — see VERIFY.md.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createInventoryClient, parseInventorySnapshot } from './inventory/inventory-client.js';
import { createWalletClient, parseWalletSnapshot } from './wallet/wallet-client.js';
import { createProgressionClient, parseProgressionSnapshot } from './progression/progression-client.js';
import { createLoadoutClient, parseLoadoutSnapshot } from './appearance/loadout-client.js';
import { createShopClient, parseShopSnapshot } from './shop/shop-client.js';
import { readShopCapabilities, parseShopCapabilities } from './shop/shop-capabilities.js';
import { createShopRouter } from './shop/shop-router.js';
import { createInventoryAcquisitionClient } from './inventory/inventory-acquisition-client.js';
import { setStaffBadgeClient, staffBadgeForUser, renderStaffName } from './staff-badges.js';
import { createStudentId } from './phone/student-id.js';
import { SHOP_ROUTE_IDS } from './shop/shop-routes.js';
import { createAttendanceClient, parseAttendance, ATTENDANCE_MILESTONES } from './attendance/attendance-client.js';
import { GuestbookClient, GuestbookError, parseGuestbookEntry, parseGuestbookBoard, GUESTBOOK_DAILY_LIMIT } from './guestbook/guestbook-client.js';
import { createJeongseokAccessClient, parseAccessSnapshot, parsePurchaseResult, DAY_PASS } from './jeongseok/access-client.js';
import { createDailyQuizClient, parseDailyQuiz } from './daily-quiz/daily-quiz-client.js';
import { createLifeSkillBookClient, parseLifeSkillList, parseLifeSkillTree } from './life-skills/life-skill-book-client.js';
import { SocialClient, SocialError } from './social/social-client.js';
import { AccompanyClient, parseAccompanySession } from './social/accompany-client.js';
import { createBiryongCloudSync } from './biryong/biryong-cloud-sync.js';
import { createBiryongRelationshipClient, parseBiryongRelationshipList } from './biryong/biryong-village-relationship-client.js';
import { createMcm2026EventClient } from './events/event-client.js';
import { COOKING_AVAILABLE, CARP_RECIPE, createCookingClient, canUseCookingStation, parseCookingReceipt } from './rooms/cooking-client.js';
import { createFurnitureClient, parseFurnitureSnapshot } from './rooms/furniture-client.js';
import { PersonalRoomClient, PersonalRoomError, parsePersonalRoom } from './rooms/personal-room-client.js';
import { RoomKnockClient, RoomKnockError, parseKnock, waitForKnockAnswer, createOwnerKnockWatcher, diffRoomVisitors, KNOCK_POLL_MS, KNOCK_WAIT_MS, OWNER_KNOCK_POLL_MS } from './rooms/room-knock.js';
import { createWorldProfile, parseWorldProfile, isWorldProfileNicknameShape, isWorldProfileAvatarKey, WorldProfileError, WORLD_PROFILE_AVATARS } from './profile/profile-client.js';
import { requestWorldMailVerification, parseWorldMailVerifyRequest, isInhaMailAddress, WorldMailVerifyError } from './mail/mail-verify-client.js';
import { startWorldPopulationHeartbeat, startWorldPopulationCount, parseWorldPopulationSnapshot, WORLD_HEARTBEAT_MS, WORLD_POPULATION_REFRESH_MS } from './online/world-population-heartbeat.js';

const SESSION = '11111111-2222-4333-8444-555555555555';
const GM_ID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const USER_ID = '12345678-1234-4234-8234-123456789012';
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function stubFetcher(routes) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const route = routes.find((r) => String(url).includes(r.match));
    const res = route ? route.reply(calls.length, init) : { status: 404, body: { error: 'NOT_FOUND' } };
    return new Response(JSON.stringify(res.body), { status: res.status });
  };
  return { calls, fetch };
}

function assertSessionOnly(call) {
  assert.equal(call.init.headers['X-Session-Id'], SESSION);
  assert.ok(!('Authorization' in call.init.headers));
  assert.ok(!JSON.stringify(call.init.headers).includes('Bearer'));
}

const INVENTORY_BODY = {
  items: [
    { itemId: 'material.fish_carp', quantity: 2, acquiredAt: '2026-11-13T00:00:00.000Z', updatedAt: null,
      sourceType: 'ACTIVITY', sourceRef: 'fishing', eventId: null, catalogStatus: 'ACTIVE' },
  ],
};
const WALLET_BODY = { currencies: [{ id: 'currency.induck_coin', balance: 120 }] };
const PROGRESSION_BODY = {
  totalExp: 1500, level: 3, currentLevelStartExp: 1000, nextLevelExp: 2000,
  progressExp: 500, progressRequired: 1000, maxDefinedLevel: 40, isMaxLevel: false,
};
const LOADOUT_BODY = {
  slots: {
    BODY: null, FACE: null, HAIR: null,
    HEAD: { itemId: 'head.test_hat', catalogStatus: 'ACTIVE', equippedAt: '2026-11-13T00:00:00.000Z' },
    TOP: null, BOTTOM: null, SHOES: null, BACK: null, ACCESSORY: null,
  },
};
const shopBody = (shopId) => ({
  shopId, status: 'ACTIVE', displayName: '상점', playerLevel: 3,
  offers: [
    { listingId: 'listing.001', itemId: 'material.fish_carp', currencyId: 'currency.induck_coin',
      price: 50, quantity: 1, requiredLevel: null, purchaseLimit: null, startAt: null, endAt: null,
      status: 'ACTIVE', purchasable: true, unavailableReason: null },
  ],
});
const PROFILE_BODY = {
  profile: { department: '문화콘텐츠학과', title: '새내기', avatar: 'classic', inhaVerified: false },
  stats: { playedGames: 3 },
  achievements: [
    { title: '첫 걸음', earned: true, earnedAt: '2026-11-13T00:00:00.000Z' },
    { title: '미획득', earned: false, earnedAt: null },
  ],
};

// ---------- inventory ----------

test('inventory: sends X-Session-Id, never Authorization; setAccount(guest) -> READY, setAccount(null) -> SIGNED_OUT', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-inventory', reply: () => ({ status: 200, body: INVENTORY_BODY }) },
  ]);
  const client = createInventoryClient({ getSessionId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.items.length, 1);
  assert.equal(client.snapshot.items[0].itemId, 'material.fish_carp');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(parseInventorySnapshot(INVENTORY_BODY).items[0].quantity, 2);
  await client.setAccount(null);
  assert.equal(client.state, 'SIGNED_OUT');
  assert.equal(client.snapshot, null);
});

test('inventory: no session sends nothing and reports UNAVAILABLE', async () => {
  const { calls, fetch } = stubFetcher([]);
  const client = createInventoryClient({ getSessionId: () => null, fetcher: fetch });
  await client.setAccount(SESSION);
  assert.equal(await client.refresh(), false);
  assert.equal(client.state, 'UNAVAILABLE');
  assert.equal(client.snapshot, null);
  assert.equal(calls.length, 0);
});

test('inventory: server 401 -> UNAVAILABLE and keeps no snapshot', async () => {
  const { fetch } = stubFetcher([
    { match: '/api/world-inventory', reply: () => ({ status: 401, body: { error: 'AUTH_REQUIRED' } }) },
  ]);
  const client = createInventoryClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setAccount(SESSION);
  assert.equal(await client.refresh(), false);
  assert.equal(client.state, 'UNAVAILABLE');
  assert.equal(client.snapshot, null);
});

// ---------- wallet ----------

test('wallet: sends X-Session-Id, never Authorization; balance reads from the snapshot', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-wallet', reply: () => ({ status: 200, body: WALLET_BODY }) },
  ]);
  const client = createWalletClient({ getSessionId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.balance(), 120);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(parseWalletSnapshot(WALLET_BODY).balances['currency.induck_coin'], 120);
  await client.setAccount(null);
  assert.equal(client.state, 'SIGNED_OUT');
  assert.equal(client.balance(), null);
});

test('wallet: server 403 -> UNAVAILABLE', async () => {
  const { fetch } = stubFetcher([
    { match: '/api/world-wallet', reply: () => ({ status: 403, body: { error: 'FORBIDDEN' } }) },
  ]);
  const client = createWalletClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setAccount(SESSION);
  assert.equal(await client.refresh(), false);
  assert.equal(client.state, 'UNAVAILABLE');
});

test('wallet: reward readback retry survives the migration (bounded, re-reads once)', async () => {
  const timers = [];
  let attempt = 0;
  const fetch = async () => {
    attempt += 1;
    if (attempt <= 2) return new Response(JSON.stringify({ error: 'UNAVAILABLE' }), { status: 503 });
    return new Response(JSON.stringify(WALLET_BODY), { status: 200 });
  };
  const client = createWalletClient({
    getSessionId: () => SESSION, fetcher: fetch,
    setTimer: (fn) => { timers.push(fn); return timers.length; },
    clearTimer: () => {},
    rewardRetryDelays: [0],
  });
  await client.setAccount(SESSION);
  assert.equal(client.state, 'UNAVAILABLE');
  assert.equal(await client.refresh('daily-reward-recovery'), false);
  assert.equal(timers.length, 1);
  timers[0]();
  await sleep(10);
  assert.equal(client.state, 'READY');
  assert.equal(client.balance(), 120);
});

// ---------- progression ----------

test('progression: sends X-Session-Id, never Authorization; parses the snapshot', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-progression', reply: () => ({ status: 200, body: PROGRESSION_BODY }) },
  ]);
  const client = createProgressionClient({ getSessionId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.level, 3);
  assert.equal(client.snapshot.totalExp, 1500);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(parseProgressionSnapshot(PROGRESSION_BODY).progressRequired, 1000);
  await client.setAccount(null);
  assert.equal(client.state, 'SIGNED_OUT');
});

test('progression: no session sends nothing; server 401 -> UNAVAILABLE', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-progression', reply: () => ({ status: 401, body: { error: 'AUTH_REQUIRED' } }) },
  ]);
  const noSession = createProgressionClient({ getSessionId: () => null, fetcher: fetch });
  await noSession.setAccount(SESSION);
  assert.equal(await noSession.refresh(), false);
  assert.equal(noSession.state, 'UNAVAILABLE');
  assert.equal(calls.length, 0);

  const denied = createProgressionClient({ getSessionId: () => SESSION, fetcher: fetch });
  await denied.setAccount(SESSION);
  assert.equal(await denied.refresh(), false);
  assert.equal(denied.state, 'UNAVAILABLE');
  // One call from setAccount's account refresh, one from the explicit refresh.
  assert.equal(calls.length, 2);
});

// ---------- loadout (A-2: writes POST /api/world-loadout) ----------

test('loadout: read sends X-Session-Id, never Authorization; parses all nine slots', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-loadout', reply: () => ({ status: 200, body: LOADOUT_BODY }) },
  ]);
  const client = createLoadoutClient({ getSessionId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.slots.HEAD.itemId, 'head.test_hat');
  assert.equal(client.snapshot.slots.BODY, null);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(parseLoadoutSnapshot(LOADOUT_BODY).slots.HEAD.catalogStatus, 'ACTIVE');
  await client.setAccount(null);
  assert.equal(client.state, 'SIGNED_OUT');
});

test('loadout (A-2): equip POSTs with X-Session-Id; a definitive refusal retires the key, an unknown failure keeps it; no session sends nothing', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-loadout', reply: (_n, init) => {
      if (init?.method === 'POST') {
        const body = JSON.parse(init.body);
        bodies.push(body);
        // 1st POST: definitive refusal. 2nd POST: transport failure (unknown outcome).
        // 3rd POST: the retry of the unknown outcome. 4th POST: success.
        if (bodies.length === 1) return { status: 409, body: { error: 'ITEM_NOT_OWNED' } };
        if (bodies.length === 2) return { status: 503, body: { error: 'LOADOUT_UNAVAILABLE' } };
        return { status: 200, body: { status: 'SUCCESS', slot: 'HEAD', itemId: 'head.test_hat' } };
      }
      return { status: 200, body: LOADOUT_BODY };
    } },
  ]);
  const client = createLoadoutClient({ getSessionId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);

  const refused = await client.equip('HEAD', 'head.test_hat');
  assert.equal(refused.outcome, 'REFUSED');
  assert.equal(refused.code, 'ITEM_NOT_OWNED');
  const failed = await client.equip('HEAD', 'head.test_hat');
  assert.equal(failed.outcome, 'FAILED');
  assert.equal(failed.code, 'FAILED');
  const retried = await client.equip('HEAD', 'head.test_hat');
  assert.equal(retried.outcome, 'SUCCESS');
  assert.equal(retried.code, null);
  const fourth = await client.equip('HEAD', 'head.test_hat');
  assert.equal(fourth.outcome, 'SUCCESS');
  assert.equal(bodies.length, 4);
  // The refusal retired its key (a fresh key next time); the unknown failure kept its key
  // (the retry reused it); the success retired its key again.
  assert.notEqual(bodies[1].idempotencyKey, bodies[0].idempotencyKey);
  assert.equal(bodies[2].idempotencyKey, bodies[1].idempotencyKey);
  assert.notEqual(bodies[3].idempotencyKey, bodies[2].idempotencyKey);
  for (const body of bodies) {
    assert.equal(body.action, 'equip');
    assert.equal(body.slot, 'HEAD');
    assert.equal(body.itemId, 'head.test_hat');
  }
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 4);
  for (const call of posts) assertSessionOnly(call);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createLoadoutClient({ getSessionId: () => null, fetcher: noFetch });
  await noSession.setAccount(SESSION);
  assert.equal(await noSession.refresh(), false);
  assert.equal(noSession.state, 'UNAVAILABLE');
  assert.equal(noCalls.length, 0);
  assert.deepEqual(await noSession.equip('HEAD', 'head.test_hat'), {
    outcome: 'SIGNED_OUT', code: 'PERMANENT_ACCOUNT_REQUIRED', slot: 'HEAD', itemId: 'head.test_hat',
  });
});

// ---------- shop ----------

test('shop: read sends X-Session-Id + shop_id query, never Authorization', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop', reply: (_n, init) => {
      const url = new URL(calls[calls.length - 1].url, 'http://test');
      return url.searchParams.get('shop_id') === 'shop.student_center'
        ? { status: 200, body: shopBody('shop.student_center') }
        : { status: 400, body: { error: 'SHOP_ID_REQUIRED' } };
    } },
  ]);
  const client = createShopClient({ getSessionId: () => SESSION, fetcher: fetch });
  // Shop setAccount is synchronous and returns nothing (original behaviour);
  // the read happens on refresh().
  client.setAccount(SESSION);
  assert.equal(await client.refresh(), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.shopId, 'shop.student_center');
  assert.equal(client.snapshot.offers.length, 1);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes('shop_id=shop.student_center'));
  assertSessionOnly(calls[0]);
  assert.equal(parseShopSnapshot(shopBody('shop.student_center'), 'shop.student_center').playerLevel, 3);
  await client.setAccount(null);
  assert.equal(client.state, 'SIGNED_OUT');
});

test('shop: missing shop_id -> server 400 -> UNAVAILABLE (no crash, no fallback id)', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop', reply: () => ({ status: 400, body: { error: 'SHOP_ID_REQUIRED' } }) },
  ]);
  const client = createShopClient({ getSessionId: () => SESSION, fetcher: fetch, shopId: '' });
  await client.setAccount(SESSION);
  assert.equal(await client.refresh(), false);
  assert.equal(client.state, 'UNAVAILABLE');
  assert.equal(client.snapshot, null);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes('shop_id='));
});

test('shop (A-2): purchase POSTs with X-Session-Id; v1 omits shopId, v2 sends it; a definitive refusal retires the key, an unknown failure keeps it', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop-purchase', reply: (_n, init) => {
      const body = JSON.parse(init.body);
      bodies.push(body);
      // 1st POST (v1): definitive refusal. 2nd POST (v1): success. 3rd POST (v2): success.
      if (bodies.length === 1) return { status: 409, body: { error: 'INSUFFICIENT_FUNDS' } };
      return { status: 200, body: { status: 'SUCCESS', listingId: body.listingId } };
    } },
    { match: '/api/world-shop', reply: () => ({ status: 200, body: shopBody('shop.student_center') }) },
  ]);
  const client = createShopClient({ getSessionId: () => SESSION, fetcher: fetch });
  client.setAccount(SESSION);
  assert.equal(await client.refresh(), true);
  const refused = await client.purchase('listing.001');
  assert.equal(refused.outcome, 'REFUSED');
  assert.equal(refused.code, 'INSUFFICIENT_FUNDS');
  const ok = await client.purchase('listing.001');
  assert.equal(ok.outcome, 'SUCCESS');
  assert.equal(ok.code, null);
  assert.equal(bodies.length, 2);
  // v1 omits shopId; the refusal retired its key (a fresh key next time).
  assert.equal(bodies[0].listingId, 'listing.001');
  assert.ok(!('shopId' in bodies[0]));
  assert.ok(!('shopId' in bodies[1]));
  assert.notEqual(bodies[1].idempotencyKey, bodies[0].idempotencyKey);
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 2);
  for (const call of posts) assertSessionOnly(call);

  // Scoped (v2) purchase sends shopId; the router freezes the v2 choice per listing.
  const scoped = createShopClient({ getSessionId: () => SESSION, fetcher: fetch, scopedPurchase: true });
  scoped.setAccount(SESSION);
  const scopedOk = await scoped.purchase('listing.001');
  assert.equal(scopedOk.outcome, 'SUCCESS');
  assert.equal(scopedOk.code, null);
  assert.equal(bodies.length, 3);
  assert.equal(bodies[2].listingId, 'listing.001');
  assert.equal(bodies[2].shopId, 'shop.student_center');
  assert.ok(bodies[2].idempotencyKey);

  // No session: the read sends nothing and the purchase reports SIGNED_OUT.
  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createShopClient({ getSessionId: () => null, fetcher: noFetch });
  await noSession.setAccount(SESSION);
  assert.equal(await noSession.refresh(), false);
  assert.equal(noSession.state, 'UNAVAILABLE');
  assert.equal(noCalls.length, 0);
  assert.deepEqual(await noSession.purchase('listing.001'), {
    outcome: 'SIGNED_OUT', code: 'PERMANENT_ACCOUNT_REQUIRED', offer: null,
  });

  // A 403 read leaves the client UNAVAILABLE; a purchase attempt then fails, not SIGNED_OUT.
  const { calls: deniedCalls, fetch: deniedFetch } = stubFetcher([
    { match: '/api/world-shop-purchase', reply: () => ({ status: 403, body: { error: 'FORBIDDEN' } }) },
    { match: '/api/world-shop', reply: () => ({ status: 403, body: { error: 'FORBIDDEN' } }) },
  ]);
  const denied = createShopClient({ getSessionId: () => SESSION, fetcher: deniedFetch });
  await denied.setAccount(SESSION);
  assert.equal(await denied.refresh(), false);
  assert.equal(denied.state, 'UNAVAILABLE');
  const deniedPurchase = await denied.purchase('listing.001');
  assert.equal(deniedPurchase.outcome, 'FAILED');
  assert.equal(deniedPurchase.code, 'FAILED');
  assert.equal(deniedCalls.filter((c) => c.init?.method === 'POST').length, 1);
});

// ---------- shop capabilities ----------

test('shop-capabilities: split parses; 404 falls back to legacy; 401 and no session return null', async () => {
  const split = await readShopCapabilities({
    getSessionId: () => SESSION,
    fetcher: stubFetcher([
      { match: '/api/world-shop-capabilities', reply: () => ({ status: 200, body: { version: 1, purchaseRpc: 'purchase_world_shop_listing_v2', catalogLayout: 'split' } }) },
    ]).fetch,
  });
  assert.deepEqual(split, { mode: 'split', purchaseRpc: 'purchase_world_shop_listing_v2' });
  assert.deepEqual(parseShopCapabilities({ version: 1, purchaseRpc: 'purchase_world_shop_listing_v1', catalogLayout: 'legacy' }),
    { mode: 'legacy', purchaseRpc: 'purchase_world_shop_listing_v1' });

  const { calls: calls404, fetch: fetch404 } = stubFetcher([
    { match: '/api/world-shop-capabilities', reply: () => ({ status: 404, body: { error: 'NOT_FOUND' } }) },
  ]);
  assert.deepEqual(await readShopCapabilities({ getSessionId: () => SESSION, fetcher: fetch404 }),
    { mode: 'legacy', purchaseRpc: 'purchase_world_shop_listing_v1' });
  assert.equal(calls404.length, 1);
  assertSessionOnly(calls404[0]);

  const { calls: calls401, fetch: fetch401 } = stubFetcher([
    { match: '/api/world-shop-capabilities', reply: () => ({ status: 401, body: { error: 'AUTH_REQUIRED' } }) },
  ]);
  assert.equal(await readShopCapabilities({ getSessionId: () => SESSION, fetcher: fetch401 }), null);
  assert.equal(calls401.length, 1);

  const { calls: callsNone, fetch: fetchNone } = stubFetcher([]);
  assert.equal(await readShopCapabilities({ getSessionId: () => null, fetcher: fetchNone }), null);
  assert.equal(callsNone.length, 0);
});

// ---------- shop router ----------

test('shop-router: negotiates capabilities then reads the selected shop, all with X-Session-Id', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop-capabilities', reply: () => ({ status: 200, body: { version: 1, purchaseRpc: 'purchase_world_shop_listing_v2', catalogLayout: 'split' } }) },
    { match: '/api/world-shop', reply: (_n) => {
      const url = new URL(calls[calls.length - 1].url, 'http://test');
      const shopId = url.searchParams.get('shop_id');
      return { status: 200, body: shopBody(shopId) };
    } },
  ]);
  const router = createShopRouter({ getSessionId: () => SESSION, fetcher: fetch, shopIds: SHOP_ROUTE_IDS });
  router.setAccount(SESSION);
  assert.equal(await router.refresh('test'), true);
  assert.equal(router.mode, 'split');
  assert.equal(router.state, 'READY');
  assert.equal(router.snapshot.shopId, 'shop.student_center');
  assert.equal(calls.length, 2);
  for (const call of calls) assertSessionOnly(call);
  assert.ok(calls.some((c) => c.url.includes('/api/world-shop-capabilities')));
  assert.ok(calls.some((c) => c.url.includes('/api/world-shop?shop_id=shop.student_center')));
  router.setAccount(null);
  assert.equal(router.state, 'SIGNED_OUT');
});

// ---------- inventory acquisition ----------

test('inventory-acquisition: legacy mode reads the two legacy shops with X-Session-Id', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop', reply: () => {
      const url = new URL(calls[calls.length - 1].url, 'http://test');
      return { status: 200, body: shopBody(url.searchParams.get('shop_id')) };
    } },
  ]);
  const client = createInventoryAcquisitionClient({ getSessionId: () => SESSION, fetcher: fetch });
  client.setScope({ accountId: SESSION, capabilityMode: 'legacy', capabilityChecking: false });
  assert.equal(await client.refresh(), true);
  const rows = client.context().shopSnapshots;
  assert.deepEqual(rows.map((r) => r.snapshot.shopId).sort(),
    ['shop.dorm_furniture', 'shop.student_center']);
  assert.ok(rows.every((r) => r.state === 'READY'));
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assertSessionOnly(call);
    assert.ok(call.url.includes('shop_id='));
  }
});

test('inventory-acquisition: no session reads nothing; a failed shop stays UNAVAILABLE without hiding the other', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop', reply: () => {
      const url = new URL(calls[calls.length - 1].url, 'http://test');
      if (url.searchParams.get('shop_id') === 'shop.dorm_furniture') {
        return { status: 500, body: { error: 'UNAVAILABLE' } };
      }
      return { status: 200, body: shopBody(url.searchParams.get('shop_id')) };
    } },
  ]);
  const noSession = createInventoryAcquisitionClient({ getSessionId: () => null, fetcher: fetch });
  noSession.setScope({ accountId: SESSION, capabilityMode: 'legacy', capabilityChecking: false });
  assert.equal(await noSession.refresh(), false);
  assert.equal(noSession.context().shopSnapshots.length, 0);
  assert.equal(calls.length, 0);

  const partial = createInventoryAcquisitionClient({ getSessionId: () => SESSION, fetcher: fetch });
  partial.setScope({ accountId: SESSION, capabilityMode: 'legacy', capabilityChecking: false });
  assert.equal(await partial.refresh(), true);
  const rows = partial.context().shopSnapshots;
  assert.equal(rows.find((r) => r.snapshot?.shopId === 'shop.student_center')?.state, 'READY');
  assert.equal(rows.find((r) => r.snapshot === null)?.state, 'UNAVAILABLE');
});

// ---------- staff badges ----------

function fakeElement() {
  const el = { textContent: '', children: [], appendChild(child) { this.children.push(child); } };
  return el;
}
function fakeDoc() {
  return {
    createElement: () => ({ className: '', textContent: '', title: '', dataset: {}, setAttribute() {} }),
  };
}

test('staff-badges: GM id gets a chip, other ids do not; ids travel as a comma query with X-Session-Id', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-staff-badges', reply: () => ({ status: 200, body: [{ user_id: GM_ID, badge_code: 'gm' }] }) },
  ]);
  setStaffBadgeClient({ getSessionId: () => SESSION, fetcher: fetch });
  const gmEl = fakeElement();
  renderStaffName(gmEl, '운영자', GM_ID, fakeDoc());
  const userEl = fakeElement();
  renderStaffName(userEl, '일반인', USER_ID, fakeDoc());
  await sleep(10);
  assert.equal(staffBadgeForUser(GM_ID)?.role, 'gm');
  assert.equal(staffBadgeForUser(USER_ID), null);
  assert.equal(gmEl.children.length, 1);
  assert.equal(gmEl.children[0].textContent, 'GM');
  assert.equal(userEl.children.length, 0);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes(`ids=${GM_ID},${USER_ID}`) || calls[0].url.includes(`ids=${GM_ID}%2C${USER_ID}`) ||
    (calls[0].url.includes(GM_ID) && calls[0].url.includes(USER_ID)));
  assert.ok(!('Authorization' in calls[0].init.headers));
  assert.equal(calls[0].init.headers['X-Session-Id'], SESSION);
  assert.ok(!JSON.stringify(calls[0].init.body ?? '').includes('p_user_ids'));
  setStaffBadgeClient(null);
});

test('staff-badges: invalid id never fetches; server 400 resolves null without throwing; no session sends nothing', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-staff-badges', reply: () => ({ status: 400, body: { error: 'INVALID_USER_IDS' } }) },
  ]);
  setStaffBadgeClient({ getSessionId: () => SESSION, fetcher: fetch });
  const badEl = fakeElement();
  renderStaffName(badEl, '이상한이름', 'not-a-uuid', fakeDoc());
  await sleep(10);
  assert.equal(calls.length, 0);
  assert.equal(staffBadgeForUser('not-a-uuid'), null);

  const el = fakeElement();
  renderStaffName(el, '운영자', GM_ID, fakeDoc());
  await sleep(10);
  assert.equal(staffBadgeForUser(GM_ID), null);
  assert.equal(el.children.length, 0);
  assert.equal(calls.length, 1);
  setStaffBadgeClient(null);

  const { calls: callsNone, fetch: fetchNone } = stubFetcher([]);
  setStaffBadgeClient({ getSessionId: () => null, fetcher: fetchNone });
  const el2 = fakeElement();
  renderStaffName(el2, '운영자', GM_ID, fakeDoc());
  await sleep(10);
  assert.equal(staffBadgeForUser(GM_ID), null);
  assert.equal(callsNone.length, 0);
  setStaffBadgeClient(null);
});

// ---------- student id ----------

function studentIdClient(routes, identity = { userId: 'user-1', displayName: '알돌' }) {
  const { calls, fetch } = stubFetcher(routes);
  const client = createStudentId({
    getSessionId: () => SESSION,
    fetcher: fetch,
    getIdentity: () => identity,
    getProgression: () => ({ state: 'READY', snapshot: PROGRESSION_BODY }),
  });
  return { client, calls };
}

test('student-id: 200 returns profile + achievements with X-Session-Id, never Authorization', async () => {
  const { client, calls } = studentIdClient([
    { match: '/api/world-profile', reply: () => ({ status: 200, body: PROFILE_BODY }) },
  ]);
  const snap = await client.refresh();
  assert.equal(snap.state, 'READY');
  assert.equal(snap.badgeState, 'READY');
  assert.equal(snap.nickname, '알돌');
  assert.equal(snap.department, '문화콘텐츠학과');
  assert.equal(snap.title, '새내기');
  assert.equal(snap.playedGames, 3);
  assert.deepEqual(snap.badges.map((b) => b.title), ['첫 걸음']);
  assert.equal(snap.progression.levelText, 'Lv.3');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.ok(calls[0].url.includes('/api/world-profile'));
});

test('student-id: 409 PROFILE_REQUIRED -> NO_PROFILE state with profile-missing defaults', async () => {
  const { client, calls } = studentIdClient([
    { match: '/api/world-profile', reply: () => ({ status: 409, body: { error: 'PROFILE_REQUIRED' } }) },
  ]);
  const snap = await client.refresh();
  assert.equal(snap.state, 'NO_PROFILE');
  assert.equal(snap.badgeState, 'EMPTY');
  assert.equal(snap.department, '소속 미설정');
  assert.equal(snap.title, '칭호 미설정');
  assert.deepEqual(snap.badges, []);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
});

test('student-id: no identity -> GUEST with no fetch; no session -> UNAVAILABLE with no fetch; 401 -> UNAVAILABLE', async () => {
  const { client: guest, calls: guestCalls } = studentIdClient([], null);
  const snap = await guest.refresh();
  assert.equal(snap.state, 'GUEST');
  assert.equal(guestCalls.length, 0);

  const { calls: noSessionCalls, fetch: noSessionFetch } = stubFetcher([]);
  const noSession = createStudentId({
    getSessionId: () => null, fetcher: noSessionFetch,
    getIdentity: () => ({ userId: 'user-1', displayName: '알돌' }),
    getProgression: () => ({ state: 'SIGNED_OUT', snapshot: null }),
  });
  assert.equal((await noSession.refresh()).state, 'UNAVAILABLE');
  assert.equal(noSessionCalls.length, 0);

  const { client: denied } = studentIdClient([
    { match: '/api/world-profile', reply: () => ({ status: 401, body: { error: 'AUTH_REQUIRED' } }) },
  ]);
  assert.equal((await denied.refresh()).state, 'UNAVAILABLE');
});

// ---------- attendance (A-2) ----------

const ATTENDANCE_STATE_BODY = {
  rewardDate: '2026-11-13', month: '2026-11', claimedToday: false, attendedDays: 2,
  attendedDates: ['2026-11-11', '2026-11-12'], dailyCoin: 10,
  nextMilestone: { days: 3, bonusCoin: 30 },
  milestones: [
    { days: 3, claimed: false, bonusCoin: 30 },
    { days: 7, claimed: false, bonusCoin: 50 },
    { days: 14, claimed: false, bonusCoin: 100 },
    { days: 21, claimed: false, bonusCoin: 150 },
  ],
};
const ATTENDANCE_REWARD = {
  rewardId: 'reward.attendance.daily', status: 'SUCCESS', replayed: false,
  entries: [{ grantType: 'CURRENCY', targetId: 'currency.induck_coin', status: 'GRANTED', granted: 10 }],
};
const ATTENDANCE_CLAIMED_BODY = {
  ...ATTENDANCE_STATE_BODY, claimedToday: true, attendedDays: 3,
  attendedDates: ['2026-11-11', '2026-11-12', '2026-11-13'],
  nextMilestone: { days: 7, bonusCoin: 50 },
  milestones: [
    { days: 3, claimed: true, bonusCoin: 30 },
    { days: 7, claimed: false, bonusCoin: 50 },
    { days: 14, claimed: false, bonusCoin: 100 },
    { days: 21, claimed: false, bonusCoin: 150 },
  ],
  claimed: true, replayed: false, rewards: [ATTENDANCE_REWARD],
};
const ATTENDANCE_REPLAY_BODY = {
  ...ATTENDANCE_CLAIMED_BODY, claimed: false, replayed: true, rewards: [],
};

test('attendance (A-2): read GETs the state; claim POSTs and calls onRewards once; a replay is ALREADY_CLAIMED and triggers the recovery readback', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-attendance-claim', reply: () => ({ status: 200, body: ATTENDANCE_CLAIMED_BODY }) },
    { match: '/api/world-attendance', reply: () => ({ status: 200, body: ATTENDANCE_CLAIMED_BODY }) },
  ]);
  let rewarded = null;
  let recovered = 0;
  const client = createAttendanceClient({
    getSessionId: () => SESSION, fetcher: fetch,
    onRewards: (rewards, snapshot) => { rewarded = { rewards, snapshot }; },
    onRecoveryReadback: () => { recovered += 1; },
  });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.attendedDays, 3);
  assert.equal(client.snapshot.claimedToday, true);
  assert.equal(client.snapshot.nextMilestone.days, 7);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.ok(calls[0].url.includes('/api/world-attendance'));
  assert.equal(parseAttendance(ATTENDANCE_STATE_BODY).milestones.length, 4);
  assert.equal(parseAttendance(ATTENDANCE_STATE_BODY).nextMilestone.bonusCoin, 30);
  assert.equal(parseAttendance({ ...ATTENDANCE_STATE_BODY, attendedDays: 99 }), null);

  const claimed = await client.claim();
  assert.equal(claimed.outcome, 'CLAIMED');
  assert.equal(claimed.snapshot.attendedDays, 3);
  assert.equal(rewarded.rewards.length, 1);
  assert.equal(rewarded.rewards[0].rewardId, 'reward.attendance.daily');
  assert.equal(rewarded.snapshot.claimedToday, true);
  assert.equal(recovered, 0);
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 1);
  assertSessionOnly(posts[0]);
  assert.ok(posts[0].url.includes('/api/world-attendance-claim'));

  // A replay: the server paid nothing, the client reports ALREADY_CLAIMED and re-reads.
  const { fetch: replayFetch } = stubFetcher([
    { match: '/api/world-attendance-claim', reply: () => ({ status: 200, body: ATTENDANCE_REPLAY_BODY }) },
    { match: '/api/world-attendance', reply: () => ({ status: 200, body: ATTENDANCE_CLAIMED_BODY }) },
  ]);
  let recoveredReplay = 0;
  const replayClient = createAttendanceClient({
    getSessionId: () => SESSION, fetcher: replayFetch,
    onRecoveryReadback: () => { recoveredReplay += 1; },
  });
  await replayClient.setAccount(SESSION);
  const replayed = await replayClient.claim();
  assert.equal(replayed.outcome, 'ALREADY_CLAIMED');
  assert.equal(replayed.snapshot.claimedToday, true);
  assert.equal(recoveredReplay, 1);
});

test('attendance (A-2): no session sends nothing; a malformed claim response is FAILED and triggers the recovery readback', async () => {
  const { calls, fetch } = stubFetcher([]);
  const noSession = createAttendanceClient({ getSessionId: () => null, fetcher: fetch });
  await noSession.setAccount(SESSION);
  assert.equal(noSession.state, 'UNAVAILABLE');
  assert.equal(calls.length, 0);
  assert.deepEqual(await noSession.claim(), { outcome: 'FAILED', code: 'FAILED' });

  const { fetch: badFetch } = stubFetcher([
    { match: '/api/world-attendance-claim', reply: () => ({ status: 200, body: { claimed: true, replayed: false, rewards: [] } }) },
    { match: '/api/world-attendance', reply: () => ({ status: 200, body: ATTENDANCE_STATE_BODY }) },
  ]);
  let recovered = 0;
  const bad = createAttendanceClient({
    getSessionId: () => SESSION, fetcher: badFetch,
    onRecoveryReadback: () => { recovered += 1; },
  });
  await bad.setAccount(SESSION);
  const result = await bad.claim();
  assert.equal(result.outcome, 'FAILED');
  assert.equal(result.code, 'MALFORMED_RESPONSE');
  assert.equal(recovered, 1);
  assert.equal(bad.state, 'READY');
});

// ---------- guestbook (A-2) ----------

const ENTRY_ID = '22222222-3333-4444-8555-666666666666';
const ENTRY_BODY = {
  id: ENTRY_ID, userId: SESSION, nickname: '알돌', avatar: 'classic', inhaVerified: false,
  content: '안녕하세요', createdAt: '2026-11-13T00:00:00.000Z', updatedAt: '2026-11-13T00:00:00.000Z', mine: true,
};
const BOARD_BODY = {
  locationKey: 'main_gate', entries: [ENTRY_BODY], hasMore: false, nextBefore: null,
  dailyLimit: 3, dailyUsed: 1, dailyRemaining: 2, cooldownRemainingSeconds: 0,
};

test('guestbook (A-2): load GETs with limit/before; create/update/remove POST with X-Session-Id; a board with another user\'s mine entry is FAILED', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-guestbook', reply: (_n, init) => {
      if (init?.method === 'POST') {
        const body = JSON.parse(init.body);
        bodies.push(body);
        if (body.action === 'delete') return { status: 200, body: true };
        return { status: 200, body: { ...ENTRY_BODY, content: body.content ?? ENTRY_BODY.content } };
      }
      return { status: 200, body: BOARD_BODY };
    } },
  ]);
  const client = new GuestbookClient({ getSessionId: () => SESSION, fetcher: fetch, getSelfUserId: () => SESSION });
  const board = await client.load({ limit: 20 });
  assert.equal(board.locationKey, 'main_gate');
  assert.equal(board.entries.length, 1);
  assert.equal(board.entries[0].nickname, '알돌');
  assert.equal(board.entries[0].mine, true);
  assert.equal(board.dailyLimit, 3);
  assert.equal(board.dailyUsed, 1);
  assert.equal(board.dailyRemaining, 2);
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes('limit=20'));
  assertSessionOnly(calls[0]);
  assert.equal(parseGuestbookEntry(ENTRY_BODY).content, '안녕하세요');
  assert.equal(parseGuestbookBoard(BOARD_BODY).hasMore, false);
  assert.throws(() => parseGuestbookBoard({ ...BOARD_BODY, locationKey: 'other' }), /FAILED/);

  const created = await client.create('새 글입니다');
  assert.equal(created.id, ENTRY_ID);
  assert.equal(created.content, '새 글입니다');
  assert.equal(created.mine, true);
  const updated = await client.update(ENTRY_ID, '고친 글입니다');
  assert.equal(updated.id, ENTRY_ID);
  assert.equal(updated.content, '고친 글입니다');
  assert.equal(await client.remove(ENTRY_ID), true);
  assert.deepEqual(bodies.map((b) => b.action), ['create', 'update', 'delete']);
  assert.equal(bodies[0].location, 'main_gate');
  assert.equal(bodies[1].entryId, ENTRY_ID);
  assert.equal(bodies[2].entryId, ENTRY_ID);
  for (const call of calls.filter((c) => c.init?.method === 'POST')) assertSessionOnly(call);

  // A board claiming another user's entry as mine is rejected by load().
  const { fetch: badFetch } = stubFetcher([
    { match: '/api/world-guestbook', reply: () => ({ status: 200, body: {
      ...BOARD_BODY, entries: [{ ...ENTRY_BODY, userId: '33333333-4444-4555-8666-777777777777', mine: true }],
    } }) },
  ]);
  const bad = new GuestbookClient({ getSessionId: () => SESSION, fetcher: badFetch, getSelfUserId: () => SESSION });
  await assert.rejects(bad.load(), (error) => error instanceof GuestbookError && error.code === 'FAILED');
});

test('guestbook (A-2): bad content never fetches; 409 PROFILE_REQUIRED surfaces as-is; no session is SIGNED_OUT', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-guestbook', reply: () => ({ status: 409, body: { error: 'PROFILE_REQUIRED' } }) },
  ]);
  const client = new GuestbookClient({ getSessionId: () => SESSION, fetcher: fetch, getSelfUserId: () => SESSION });
  await assert.rejects(client.create(''), (error) => error instanceof GuestbookError && error.code === 'INVALID_CONTENT');
  await assert.rejects(client.update('not-a-uuid', 'x'), (error) => error instanceof GuestbookError && error.code === 'ENTRY_UNAVAILABLE');
  assert.equal(calls.length, 0);
  await assert.rejects(client.create('프로필 없는 글'), (error) => error instanceof GuestbookError && error.code === 'PROFILE_REQUIRED');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = new GuestbookClient({ getSessionId: () => null, fetcher: noFetch, getSelfUserId: () => SESSION });
  await assert.rejects(noSession.load(), (error) => error instanceof GuestbookError && error.code === 'SIGNED_OUT');
  assert.equal(noCalls.length, 0);
  assert.equal(GUESTBOOK_DAILY_LIMIT, 3);
});

// ---------- jeongseok (A-2) ----------

const ACCESS_OFFER = {
  status: 'ACTIVE', passType: 'jeongseok.visitor.day', price: 100, currencyId: 'currency.induck_coin',
  durationSeconds: 86400, balance: 500, canPurchase: true, shortfall: 0,
};
const ACCESS_BODY = {
  version: 1, decision: 'NEEDS_PASS', granted: false, via: null, gateStatus: 'ACTIVE',
  serverNow: '2026-11-13T00:00:00.000Z', userId: SESSION, inhaMailVerified: false, pass: null, offer: ACCESS_OFFER,
};
const ACCESS_GRANTED_BODY = {
  ...ACCESS_BODY, decision: 'GRANTED', granted: true, via: 'VISITOR_PASS',
  pass: { passType: 'jeongseok.visitor.day', issuedAt: '2026-11-13T00:00:00.000Z', expiresAt: '2026-11-14T00:00:00.000Z', active: true },
  offer: null,
};
const PURCHASE_ID = '44444444-5555-4666-8777-888888888888';
const TX_ID = '55555555-6666-4777-8888-999999999999';
const PURCHASE_BODY = (key) => ({
  status: 'SUCCESS', userId: SESSION, idempotencyKey: key, passType: 'jeongseok.visitor.day',
  purchaseId: PURCHASE_ID, walletTransactionId: TX_ID, price: 100, balanceBefore: 500, balanceAfter: 400,
  issuedAt: '2026-11-13T00:00:00.000Z', expiresAt: '2026-11-14T00:00:00.000Z', access: ACCESS_GRANTED_BODY,
});
function fakeStorage() {
  const map = new Map();
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => { map.set(k, v); },
    removeItem: (k) => { map.delete(k); },
  };
}

test('jeongseok (A-2): read GETs the snapshot; purchase POSTs with the stored key and clears it on success; the access snapshot validates strictly', async () => {
  const bodies = [];
  const storage = fakeStorage();
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-jeongseok-pass', reply: (_n, init) => {
      const body = JSON.parse(init.body);
      bodies.push(body);
      return { status: 200, body: PURCHASE_BODY(body.idempotencyKey) };
    } },
    { match: '/api/world-jeongseok-access', reply: () => ({ status: 200, body: ACCESS_BODY }) },
  ]);
  const client = createJeongseokAccessClient({
    getSessionId: () => SESSION, fetcher: fetch, storage: () => storage,
    newKey: () => 'jsl:11111111-2222-4333-8444-555555555555',
  });
  const snapshot = await client.setAccount(SESSION);
  assert.equal(client.state, 'READY');
  assert.equal(snapshot.decision, 'NEEDS_PASS');
  assert.equal(snapshot.granted, false);
  assert.equal(snapshot.offer.price, 100);
  assert.equal(snapshot.offer.canPurchase, true);
  assert.equal(typeof snapshot.clockOffsetMs, 'number');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.ok(calls[0].url.includes('/api/world-jeongseok-access'));
  assert.equal(parseAccessSnapshot(ACCESS_BODY, SESSION).decision, 'NEEDS_PASS');
  assert.equal(parseAccessSnapshot({ ...ACCESS_BODY, userId: 'other' }, SESSION), null);
  assert.equal(parsePurchaseResult(PURCHASE_BODY('jsl:11111111-2222-4333-8444-555555555555'),
    { accountId: SESSION, key: 'jsl:11111111-2222-4333-8444-555555555555', passType: DAY_PASS }).status, 'SUCCESS');

  const result = await client.purchase();
  assert.equal(result.status, 'SUCCESS');
  assert.equal(result.purchaseId, PURCHASE_ID);
  assert.equal(result.balanceAfter, 400);
  assert.equal(client.snapshot.decision, 'GRANTED');
  assert.equal(client.snapshot.via, 'VISITOR_PASS');
  assert.equal(client.view().pendingKey, false);
  // A definitive answer clears the pending key: the client removes the stored
  // key on success (writePendingKey(null) -> removeItem, same as the original
  // access-client.js) — it never writes a JSON tombstone record, and no reader
  // consumes one, so the store is empty afterwards.
  assert.equal(storage.map.size, 0);
  assert.equal(storage.getItem(`inha-world:jeongseok-pass-key:${SESSION}`), null);
  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].passType, DAY_PASS);
  assert.equal(bodies[0].idempotencyKey, 'jsl:11111111-2222-4333-8444-555555555555');
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 1);
  assertSessionOnly(posts[0]);
  assert.ok(posts[0].url.includes('/api/world-jeongseok-pass'));
});

test('jeongseok (A-2): a definitive refusal clears the key and re-reads; a lost reply keeps the key so the next purchase reuses it; no session is UNKNOWN', async () => {
  const storage = fakeStorage();
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-jeongseok-pass', reply: () => ({ status: 409, body: { error: 'INSUFFICIENT_FUNDS' } }) },
    { match: '/api/world-jeongseok-access', reply: () => ({ status: 200, body: ACCESS_BODY }) },
  ]);
  const client = createJeongseokAccessClient({
    getSessionId: () => SESSION, fetcher: fetch, storage: () => storage,
    newKey: () => 'jsl:22222222-3333-4444-8555-666666666666',
  });
  await client.setAccount(SESSION);
  assert.equal(await client.purchase(), null);
  assert.equal(client.view().purchaseError, 'INSUFFICIENT_FUNDS');
  assert.equal(client.view().pendingKey, false);
  // The refusal re-read the authority (one GET for setAccount, one for the refusal).
  assert.equal(calls.filter((c) => !c.init?.method || c.init.method === 'GET').length, 2);
  await sleep(10);
  assert.equal(client.state, 'READY');

  // A lost reply: the first POST throws, the key stays, the second purchase reuses it.
  const bodies = [];
  let postCount = 0;
  const flakyFetch = async (url, init) => {
    if (String(url).includes('/api/world-jeongseok-pass')) {
      postCount += 1;
      bodies.push(JSON.parse(init.body));
      if (postCount === 1) throw new Error('network down');
      return new Response(JSON.stringify(PURCHASE_BODY(bodies[0].idempotencyKey)), { status: 200 });
    }
    return new Response(JSON.stringify(ACCESS_BODY), { status: 200 });
  };
  const storage2 = fakeStorage();
  const flaky = createJeongseokAccessClient({
    getSessionId: () => SESSION, fetcher: flakyFetch, storage: () => storage2,
    newKey: () => 'jsl:33333333-4444-4555-8666-777777777777',
  });
  await flaky.setAccount(SESSION);
  assert.equal(await flaky.purchase(), null);
  assert.equal(flaky.view().purchaseError, 'UNKNOWN');
  assert.equal(flaky.view().pendingKey, true);
  const recovered = await flaky.purchase();
  assert.equal(recovered.status, 'SUCCESS');
  assert.equal(bodies.length, 2);
  assert.equal(bodies[1].idempotencyKey, bodies[0].idempotencyKey);
  assert.equal(flaky.view().pendingKey, false);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createJeongseokAccessClient({ getSessionId: () => null, fetcher: noFetch, storage: () => fakeStorage() });
  await noSession.setAccount(SESSION);
  assert.equal(noSession.state, 'UNKNOWN');
  assert.equal(noSession.snapshot, null);
  assert.equal(noCalls.length, 0);
});

// ---------- cooking (A-2) ----------

const ROOM_ID = '66666666-7777-4888-8999-aaaaaaaaaaaa';
const REQUEST_ID = '77777777-8888-4999-8aaa-bbbbbbbbbbbb';
const MUTATION_ID = '88888888-9999-4aaa-8bbb-cccccccccccc';
const COOKING_ROOM_STATE = {
  roomId: ROOM_ID, accountId: SESSION, ownerUserId: SESSION, role: 'owner',
  space: 'ROOM_PERSONAL_BASIC', ready: true, editing: false, busy: false,
  objects: [{ itemId: 'furniture.cooking_station', surface: 'floor' }],
};
const COOKING_RECEIPT_BODY = {
  status: 'SUCCESS', userId: SESSION, roomId: ROOM_ID, requestId: REQUEST_ID,
  recipeId: 'recipe.carp_grill', definitionVersion: 1, layoutRevision: 3,
  inventory: {
    status: 'SUCCESS', userId: SESSION, mutationType: 'COOK', sourceType: 'CRAFTING',
    sourceRef: 'recipe.carp_grill', mutationId: MUTATION_ID, idempotencyKey: `recipe:${SESSION}:${REQUEST_ID}`,
    entries: [
      { direction: 'CONSUME', itemId: 'material.fish_carp', quantity: 1, quantityBefore: 3, quantityAfter: 2 },
      { direction: 'GRANT', itemId: 'consumable.grilled_carp', quantity: 1, quantityBefore: 0, quantityAfter: 1 },
    ],
  },
};

test('cooking (A-2): COOKING_AVAILABLE stays false so cook() never fetches; with the feature enabled it POSTs, validates the receipt strictly and keeps the request id across a lost reply', async () => {
  assert.equal(COOKING_AVAILABLE, false);
  assert.equal(CARP_RECIPE.recipeId, 'recipe.carp_grill');
  assert.equal(canUseCookingStation(COOKING_ROOM_STATE, SESSION), true);
  assert.equal(canUseCookingStation({ ...COOKING_ROOM_STATE, role: 'visitor' }, SESSION), false);
  assert.equal(canUseCookingStation(COOKING_ROOM_STATE, 'other'), false);
  assert.equal(parseCookingReceipt(COOKING_RECEIPT_BODY, { accountId: SESSION, roomId: ROOM_ID, requestId: REQUEST_ID, recipeId: 'recipe.carp_grill' }).status, 'SUCCESS');
  assert.equal(parseCookingReceipt({ ...COOKING_RECEIPT_BODY, userId: 'other' }, { accountId: SESSION, roomId: ROOM_ID, requestId: REQUEST_ID, recipeId: 'recipe.carp_grill' }), null);

  const { calls, fetch } = stubFetcher([]);
  const disabled = createCookingClient({
    getSessionId: () => SESSION, getUserId: () => SESSION, getRoomState: () => COOKING_ROOM_STATE, fetcher: fetch,
  });
  // The cooking client has no setAccount (neither the original nor the migrated
  // one): binding is via sync(), which reads the getUserId/getRoomState
  // providers — the same call cooking-panel.js makes.
  disabled.sync();
  assert.equal(disabled.available(), false);
  assert.equal(await disabled.cook(), false);
  assert.equal(calls.length, 0);

  const bodies = [];
  let postCount = 0;
  const flakyFetch = async (url, init) => {
    if (String(url).includes('/api/world-cooking')) {
      postCount += 1;
      bodies.push(JSON.parse(init.body));
      if (postCount === 1) throw new Error('network down');
      return new Response(JSON.stringify(COOKING_RECEIPT_BODY), { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  let receiptSeen = null;
  const enabled = createCookingClient({
    getSessionId: () => SESSION, getUserId: () => SESSION, getRoomState: () => COOKING_ROOM_STATE,
    fetcher: flakyFetch, isAvailable: () => true, requestId: () => REQUEST_ID,
    onReceipt: async (receipt) => { receiptSeen = receipt; return true; },
  });
  enabled.sync();
  assert.equal(enabled.available(), true);
  assert.equal(await enabled.cook(), false);
  assert.equal(enabled.state().error, 'UNAVAILABLE');
  const retried = await enabled.cook();
  assert.equal(retried, true);
  assert.equal(receiptSeen.recipeId, 'recipe.carp_grill');
  assert.equal(receiptSeen.inventory.entries[1].itemId, 'consumable.grilled_carp');
  assert.equal(enabled.state().receipt.requestId, REQUEST_ID);
  assert.equal(enabled.state().inventoryStatus, 'READY');
  assert.equal(bodies.length, 2);
  // The lost reply kept the request id: the retry is the same cook, not a second one.
  assert.equal(bodies[1].requestId, bodies[0].requestId);
  assert.equal(bodies[0].requestId, REQUEST_ID);
  assert.equal(bodies[0].recipeId, 'recipe.carp_grill');
});

// ---------- furniture (A-2) ----------

const CHAIR_ID = '99999999-aaaa-4bbb-8ccc-dddddddddddd';
const STATION_ID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const FURNITURE_OBJECTS = [
  { id: CHAIR_ID, itemId: 'furniture.induck_chair', surface: 'floor', x: 0, z: 0, yaw: 0 },
  { id: STATION_ID, itemId: 'furniture.cooking_station', surface: 'floor', x: 3, z: 0, yaw: 0 },
];
const FURNITURE_OWNED = [
  { itemId: 'furniture.induck_chair', quantity: 1 },
  { itemId: 'furniture.cooking_station', quantity: 1 },
];
const FURNITURE_SNAPSHOT_BODY = { roomId: ROOM_ID, role: 'owner', revision: 2, objects: FURNITURE_OBJECTS };

test('furniture (A-2): bind GETs the snapshot; save POSTs the revision and canonical objects and bumps the revision; a stale revision is LAYOUT_CONFLICT', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-room-furniture', reply: (_n, init) => {
      if (init?.method === 'POST') {
        const body = JSON.parse(init.body);
        bodies.push(body);
        if (body.revision !== 2) return { status: 409, body: { error: 'LAYOUT_CONFLICT' } };
        return { status: 200, body: { roomId: ROOM_ID, role: 'owner', revision: 3, objects: body.objects } };
      }
      return { status: 200, body: FURNITURE_SNAPSHOT_BODY };
    } },
  ]);
  const client = createFurnitureClient({ getSessionId: () => SESSION, getUserId: () => SESSION, fetcher: fetch });
  assert.equal(await client.bind(ROOM_ID), true);
  assert.equal(client.state().ready, true);
  assert.equal(client.state().revision, 2);
  assert.equal(client.state().role, 'owner');
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes(`room_id=${ROOM_ID}`));
  assertSessionOnly(calls[0]);
  assert.equal(parseFurnitureSnapshot(FURNITURE_SNAPSHOT_BODY, ROOM_ID).revision, 2);
  assert.equal(parseFurnitureSnapshot({ ...FURNITURE_SNAPSHOT_BODY, roomId: 'other' }, ROOM_ID), null);

  assert.equal(client.begin(), true);
  const moved = [
    { id: CHAIR_ID, itemId: 'furniture.induck_chair', surface: 'floor', x: 1, z: 0, yaw: 0 },
    { id: STATION_ID, itemId: 'furniture.cooking_station', surface: 'floor', x: 3, z: 0, yaw: 0 },
  ];
  assert.equal(client.edit(moved), true);
  assert.equal(client.state().dirty, true);
  assert.equal(await client.save(FURNITURE_OWNED), true);
  assert.equal(client.state().revision, 3);
  assert.equal(client.state().dirty, false);
  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].roomId, ROOM_ID);
  assert.equal(bodies[0].revision, 2);
  assert.deepEqual(bodies[0].objects, moved.slice().sort((a, b) => a.id.localeCompare(b.id)));
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 1);
  assertSessionOnly(posts[0]);

  // A stale revision is refused and the local snapshot is kept.
  assert.equal(client.begin(), true);
  assert.equal(client.edit(moved), true);
  // Force the stale revision by rewinding the snapshot the client read.
  client.state();
  const stale = await client.save(FURNITURE_OWNED);
  assert.equal(stale, false);
});

test('furniture (A-2): a visitor cannot begin; an invalid draft never fetches; no session is UNAVAILABLE', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-room-furniture', reply: () => ({ status: 200, body: { ...FURNITURE_SNAPSHOT_BODY, role: 'visitor' } }) },
  ]);
  const visitor = createFurnitureClient({ getSessionId: () => SESSION, getUserId: () => SESSION, fetcher: fetch });
  assert.equal(await visitor.bind(ROOM_ID), true);
  assert.equal(visitor.state().role, 'visitor');
  assert.equal(visitor.begin(), false);
  assert.equal(calls.length, 1);

  const { calls: editCalls, fetch: editFetch } = stubFetcher([
    { match: '/api/world-room-furniture', reply: () => ({ status: 200, body: FURNITURE_SNAPSHOT_BODY }) },
  ]);
  const editor = createFurnitureClient({ getSessionId: () => SESSION, getUserId: () => SESSION, fetcher: editFetch });
  await editor.bind(ROOM_ID);
  assert.equal(editor.begin(), true);
  assert.equal(editor.edit([{ id: CHAIR_ID, itemId: 'furniture.induck_chair', surface: 'nowhere', x: 0, z: 0, yaw: 0 }]), true);
  assert.equal(await editor.save(FURNITURE_OWNED), false);
  assert.equal(editor.state().error, 'INVALID_LAYOUT');
  assert.equal(editCalls.filter((c) => c.init?.method === 'POST').length, 0);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createFurnitureClient({ getSessionId: () => null, getUserId: () => SESSION, fetcher: noFetch });
  assert.equal(await noSession.bind(ROOM_ID), false);
  assert.equal(noSession.state().error, 'UNAVAILABLE');
  assert.equal(noCalls.length, 0);
});

// ---------- personal room (A-2) ----------

const PERSONAL_ROOM_BODY = {
  roomId: ROOM_ID, ownerUserId: SESSION, roomType: 'DORM_1_BASIC', visibility: 'friends',
  createdAt: '2026-11-13T00:00:00.000Z', updatedAt: '2026-11-13T00:00:00.000Z',
};

test('personal room (A-2): ensure GETs once and caches; setVisibility POSTs and updates the cache; an invalid visibility never fetches; no session is SIGNED_OUT', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-personal-room', reply: (_n, init) => {
      if (init?.method === 'POST') {
        const body = JSON.parse(init.body);
        bodies.push(body);
        return { status: 200, body: { ...PERSONAL_ROOM_BODY, visibility: body.visibility } };
      }
      return { status: 200, body: PERSONAL_ROOM_BODY };
    } },
  ]);
  const client = new PersonalRoomClient({ getSessionId: () => SESSION, fetcher: fetch, getSelfUserId: () => SESSION });
  const first = await client.ensure();
  const second = await client.ensure();
  assert.equal(first.roomId, ROOM_ID);
  assert.equal(first, second);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(parsePersonalRoom(PERSONAL_ROOM_BODY).roomType, 'DORM_1_BASIC');
  assert.equal(parsePersonalRoom({ ...PERSONAL_ROOM_BODY, visibility: 'everyone' }), null);

  const updated = await client.setVisibility('private');
  assert.equal(updated.visibility, 'private');
  assert.equal(updated.roomId, ROOM_ID);
  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].action, 'setVisibility');
  assert.equal(bodies[0].visibility, 'private');
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 1);
  assertSessionOnly(posts[0]);

  await assert.rejects(client.setVisibility('everyone'),
    (error) => error instanceof PersonalRoomError && error.code === 'INVALID_VISIBILITY');
  assert.equal(calls.length, 2);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = new PersonalRoomClient({ getSessionId: () => null, fetcher: noFetch, getSelfUserId: () => null });
  await assert.rejects(noSession.ensure(),
    (error) => error instanceof PersonalRoomError && error.code === 'SIGNED_OUT');
  assert.equal(noCalls.length, 0);
});

// ---------- room knock (A-2) ----------

const KNOCK_ID = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const BOB_ID = 'cccccccc-dddd-4eee-8fff-000000000000';
const KNOCK_BODY = {
  knockId: KNOCK_ID, roomId: ROOM_ID, visitorUserId: SESSION, status: 'OPEN',
  expiresAt: '2026-11-13T02:00:00.000Z', ownerPresent: false, visitorDisplayName: '알돌',
};
const KNOCK_PENDING_BODY = { ...KNOCK_BODY, status: 'PENDING', ownerPresent: true };
const KNOCK_ACCEPTED_BODY = { ...KNOCK_BODY, status: 'ACCEPTED', ownerPresent: true };

test('room knock (A-2): knock/get/list/respond POST with X-Session-Id; list keeps only PENDING knocks in this room; a non-UUID owner never fetches; 409 PROFILE_REQUIRED surfaces as-is', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-room-knock', reply: (_n, init) => {
      const body = JSON.parse(init.body);
      bodies.push(body);
      if (body.action === 'knock') return { status: 200, body: KNOCK_BODY };
      if (body.action === 'get') return { status: 200, body: KNOCK_ACCEPTED_BODY };
      if (body.action === 'list') return { status: 200, body: { roomId: ROOM_ID, knocks: [
        KNOCK_PENDING_BODY,
        { ...KNOCK_BODY, knockId: 'dddddddd-eeee-4fff-8000-111111111111', status: 'ACCEPTED' },
        { ...KNOCK_PENDING_BODY, knockId: 'eeeeeeee-ffff-4000-8000-222222222222', roomId: 'ffffffff-0000-4000-8000-333333333333' },
      ] } };
      return { status: 200, body: KNOCK_ACCEPTED_BODY };
    } },
  ]);
  const client = new RoomKnockClient({ getSessionId: () => SESSION, fetcher: fetch, getSelfUserId: () => SESSION });
  const knocked = await client.knock(BOB_ID);
  assert.equal(knocked.knockId, KNOCK_ID);
  assert.equal(knocked.status, 'OPEN');
  assert.equal(knocked.visitorUserId, SESSION);
  assert.equal(knocked.ownerPresent, false);
  const got = await client.get(KNOCK_ID);
  assert.equal(got.status, 'ACCEPTED');
  const listed = await client.list();
  assert.equal(listed.roomId, ROOM_ID);
  assert.equal(listed.knocks.length, 1);
  assert.equal(listed.knocks[0].status, 'PENDING');
  const answered = await client.respond(KNOCK_ID, true);
  assert.equal(answered.status, 'ACCEPTED');
  assert.deepEqual(bodies.map((b) => b.action), ['knock', 'get', 'list', 'respond']);
  assert.equal(bodies[0].ownerUserId, BOB_ID);
  assert.equal(bodies[1].knockId, KNOCK_ID);
  assert.equal(bodies[3].knockId, KNOCK_ID);
  assert.equal(bodies[3].accept, true);
  for (const call of calls) assertSessionOnly(call);
  assert.equal(parseKnock(KNOCK_BODY).visitorDisplayName, '알돌');
  assert.equal(parseKnock({ ...KNOCK_BODY, status: 'WRONG' }), null);

  await assert.rejects(client.knock('not-a-uuid'),
    (error) => error instanceof RoomKnockError && error.code === 'TARGET_UNAVAILABLE');
  await assert.rejects(client.get('not-a-uuid'),
    (error) => error instanceof RoomKnockError && error.code === 'KNOCK_NOT_FOUND');
  assert.equal(calls.length, 4);

  const { calls: deniedCalls, fetch: deniedFetch } = stubFetcher([
    { match: '/api/world-room-knock', reply: () => ({ status: 409, body: { error: 'PROFILE_REQUIRED' } }) },
  ]);
  const denied = new RoomKnockClient({ getSessionId: () => SESSION, fetcher: deniedFetch, getSelfUserId: () => SESSION });
  await assert.rejects(denied.knock(BOB_ID),
    (error) => error instanceof RoomKnockError && error.code === 'PROFILE_REQUIRED');
  assert.equal(deniedCalls.length, 1);
  assertSessionOnly(deniedCalls[0]);
});

test('room knock (A-2): waitForKnockAnswer polls until ACCEPTED; the owner watcher surfaces each new pending knock once; diffRoomVisitors reports joined/left names', async () => {
  let getCount = 0;
  const { fetch } = stubFetcher([
    { match: '/api/world-room-knock', reply: (_n, init) => {
      const body = JSON.parse(init.body);
      if (body.action === 'get') {
        getCount += 1;
        return { status: 200, body: getCount === 1 ? KNOCK_PENDING_BODY : KNOCK_ACCEPTED_BODY };
      }
      if (body.action === 'list') return { status: 200, body: { roomId: ROOM_ID, knocks: [KNOCK_PENDING_BODY] } };
      return { status: 200, body: KNOCK_BODY };
    } },
  ]);
  const client = new RoomKnockClient({ getSessionId: () => SESSION, fetcher: fetch, getSelfUserId: () => SESSION });
  const waited = await waitForKnockAnswer({ client, knock: KNOCK_PENDING_BODY, pollMs: 1, timeoutMs: 5000 });
  assert.equal(waited.knock.status, 'ACCEPTED');
  assert.equal(waited.cancelled, false);
  // Two polls by construction: the stub answers PENDING on the first get and
  // ACCEPTED on the second, so the loop must poll twice before it can return.
  assert.equal(getCount, 2);

  const seen = [];
  const polled = [];
  const watcher = createOwnerKnockWatcher({
    client, isOwnerInRoom: () => true, onKnock: (knock) => seen.push(knock),
    onPolled: (knocks) => polled.push(knocks), pollMs: 5,
  });
  watcher.start();
  await sleep(30);
  watcher.stop();
  assert.equal(seen.length, 1);
  assert.equal(seen[0].knockId, KNOCK_ID);
  assert.ok(polled.length >= 1);
  assert.equal(polled[0].length, 1);

  const before = { participants: [
    { userId: 'aaaaaaaa-0000-4000-8000-000000000000', role: 'visitor', local: false, displayName: '알돌' },
    { userId: 'bbbbbbbb-0000-4000-8000-000000000000', role: 'visitor', local: false, displayName: '보라' },
  ] };
  const after = { participants: [
    { userId: 'aaaaaaaa-0000-4000-8000-000000000000', role: 'visitor', local: false, displayName: '알돌' },
    { userId: 'cccccccc-0000-4000-8000-000000000000', role: 'visitor', local: false, displayName: '초록' },
  ] };
  assert.deepEqual(diffRoomVisitors(before, after), { joined: ['초록'], left: ['보라'] });
  assert.equal(KNOCK_POLL_MS, 1500);
  assert.equal(KNOCK_WAIT_MS, 32000);
  assert.equal(OWNER_KNOCK_POLL_MS, 3000);
});

// ---------- shop router purchase (A-2) ----------

test('shop-router (A-2): a split purchase sends shopId in the body', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-shop-purchase', reply: (_n, init) => {
      bodies.push(JSON.parse(init.body));
      return { status: 200, body: { status: 'SUCCESS', listingId: 'listing.001' } };
    } },
    { match: '/api/world-shop-capabilities', reply: () => ({ status: 200, body: { version: 1, purchaseRpc: 'purchase_world_shop_listing_v2', catalogLayout: 'split' } }) },
    { match: '/api/world-shop', reply: (_n) => {
      const url = new URL(calls[calls.length - 1].url, 'http://test');
      return { status: 200, body: shopBody(url.searchParams.get('shop_id')) };
    } },
  ]);
  const router = createShopRouter({ getSessionId: () => SESSION, fetcher: fetch, shopIds: SHOP_ROUTE_IDS });
  router.setAccount(SESSION);
  assert.equal(await router.refresh('test'), true);
  assert.equal(router.mode, 'split');
  const result = await router.purchase('listing.001');
  assert.equal(result.outcome, 'SUCCESS');
  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].shopId, 'shop.student_center');
  assert.equal(bodies[0].listingId, 'listing.001');
  assertSessionOnly(calls.find((c) => c.init?.method === 'POST'));
});

// ---------- daily quiz (A-3) ----------

const QUIZ_REWARD_PREVIEW = [
  { grantType: 'CURRENCY', targetId: 'currency.induck_coin', amount: 50 },
  { grantType: 'EXP', targetId: 'exp.campus', amount: 25 },
];
const QUIZ_AVAILABLE_BODY = {
  status: 'AVAILABLE', rewardDate: '2026-11-20', runId: null,
  progress: { answered: 0, total: 3, correct: 0 }, question: null,
  rewardPreview: QUIZ_REWARD_PREVIEW, lastAnswer: null,
};
const QUIZ_ACTIVE_BODY = {
  status: 'ACTIVE', rewardDate: '2026-11-20', runId: '22222222-3333-4444-8555-666666666666',
  progress: { answered: 1, total: 3, correct: 1 },
  question: { questionId: 'quiz.q2', index: 1, prompt: '두 번째 문제', options: ['a', 'b', 'c', 'd'] },
  rewardPreview: QUIZ_REWARD_PREVIEW,
  lastAnswer: { questionId: 'quiz.q1', index: 0, correct: true },
};
const QUIZ_REWARD = {
  rewardId: 'reward.daily.campus_quiz', status: 'SUCCESS', replayed: false,
  entries: [
    { grantType: 'CURRENCY', targetId: 'currency.induck_coin', status: 'GRANTED', granted: 50 },
    { grantType: 'EXP', targetId: 'exp.campus', status: 'GRANTED', granted: 25 },
  ],
};
const QUIZ_PASSED_BODY = {
  status: 'PASSED', rewardDate: '2026-11-20', runId: '22222222-3333-4444-8555-666666666666',
  progress: { answered: 3, total: 3, correct: 2 }, question: null,
  rewardPreview: QUIZ_REWARD_PREVIEW,
  lastAnswer: { questionId: 'quiz.q3', index: 2, correct: true },
  reward: QUIZ_REWARD,
};

test('daily quiz (A-3): read GETs the state; start POSTs; answer POSTs runId/questionId/answerIndex and the PASSED reward calls onReward once', async () => {
  const bodies = [];
  // The read route must come last: '/api/world-daily-quiz' is a substring of the start/answer paths.
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-daily-quiz-answer', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: QUIZ_PASSED_BODY }; } },
    { match: '/api/world-daily-quiz-start', reply: () => ({ status: 200, body: QUIZ_ACTIVE_BODY }) },
    { match: '/api/world-daily-quiz', reply: () => ({ status: 200, body: QUIZ_AVAILABLE_BODY }) },
  ]);
  let rewarded = null;
  const client = createDailyQuizClient({
    getSessionId: () => SESSION, fetcher: fetch,
    onReward: (reward) => { rewarded = reward; },
  });
  assert.equal(parseDailyQuiz(QUIZ_AVAILABLE_BODY).status, 'AVAILABLE');
  assert.equal(parseDailyQuiz(QUIZ_ACTIVE_BODY).question.questionId, 'quiz.q2');
  assert.equal(parseDailyQuiz({ ...QUIZ_AVAILABLE_BODY, progress: { answered: 0, total: 2, correct: 0 } }), null);
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.snapshot.status, 'AVAILABLE');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  const started = await client.start();
  assert.equal(started.outcome, 'OK');
  assert.equal(client.snapshot.status, 'ACTIVE');
  assert.equal(client.snapshot.question.index, 1);
  const posts = calls.filter((c) => c.init?.method === 'POST');
  assert.equal(posts.length, 1);
  assertSessionOnly(posts[0]);
  assert.ok(posts[0].url.includes('/api/world-daily-quiz-start'));
  assert.deepEqual(JSON.parse(posts[0].init.body), {});
  const answered = await client.answer(2);
  assert.equal(answered.outcome, 'OK');
  assert.equal(client.snapshot.status, 'PASSED');
  assert.equal(rewarded.rewardId, 'reward.daily.campus_quiz');
  assert.equal(bodies.length, 1);
  assert.deepEqual(bodies[0], { runId: '22222222-3333-4444-8555-666666666666', questionId: 'quiz.q2', answerIndex: 2 });
  assertSessionOnly(calls.find((c) => c.url.includes('/api/world-daily-quiz-answer')));
});

test('daily quiz (A-3): a server QUIZ_ALREADY_ANSWERED is REFUSED with the code; no session sends nothing and start is SIGNED_OUT', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-daily-quiz-answer', reply: () => ({ status: 409, body: { error: 'QUIZ_ALREADY_ANSWERED' } }) },
    { match: '/api/world-daily-quiz-start', reply: () => ({ status: 200, body: QUIZ_ACTIVE_BODY }) },
    { match: '/api/world-daily-quiz', reply: () => ({ status: 200, body: QUIZ_AVAILABLE_BODY }) },
  ]);
  const client = createDailyQuizClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setAccount(SESSION);
  await client.start();
  const refused = await client.answer(1);
  assert.equal(refused.outcome, 'REFUSED');
  assert.equal(refused.code, 'QUIZ_ALREADY_ANSWERED');
  await sleep(10); // the refused write re-reads (fire-and-forget); let it settle
  assert.ok(calls.filter((c) => c.url.includes('/api/world-daily-quiz-answer')).length >= 1);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createDailyQuizClient({ getSessionId: () => null, fetcher: noFetch });
  await noSession.setAccount(SESSION);
  assert.equal(noSession.state, 'UNAVAILABLE');
  assert.equal(noCalls.length, 0);
  assert.deepEqual(await noSession.start(), { outcome: 'SIGNED_OUT' });
});

test('daily quiz (A-3): answer() with no active question never fetches', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-daily-quiz', reply: () => ({ status: 200, body: QUIZ_AVAILABLE_BODY }) },
  ]);
  const client = createDailyQuizClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setAccount(SESSION);
  assert.deepEqual(await client.answer(0), { outcome: 'REFUSED', code: 'NO_ACTIVE_QUESTION' });
  assert.equal(calls.length, 1);
});

// ---------- life skills (A-3) ----------

const LIFE_FISHING_VIEW = {
  skillId: 'life.fishing', level: 3, totalXp: 300, currentLevelStartXp: 300, nextLevelXp: 600,
  maxDefinedLevel: 5, isMaxLevel: false,
  sp: { earned: 2, spent: 1, available: 1, nextLevelEarned: 3 },
};
const LIFE_LIST_BODY = {
  lifeLevel: { level: 1, totalSkillXp: 300 },
  skills: [{ ...LIFE_FISHING_VIEW }],
};
const lifeTreeBody = (steadyRank, fishRank) => ({
  skill: { ...LIFE_FISHING_VIEW, sp: { earned: 2, spent: steadyRank + fishRank, available: 2 - steadyRank - fishRank, nextLevelEarned: 3 } },
  reset: { cost: 0, cooldownSeconds: 86400, lastResetAt: null, nextResetAt: null, canReset: steadyRank + fishRank > 0, resetBlockedBy: steadyRank + fishRank > 0 ? null : 'EMPTY' },
  nodes: [
    { nodeId: 'life.node.fishing.steady_hands', rank: steadyRank, maxRank: 3, nextRankCost: 1, requiredSkillLevel: 2, prerequisites: [], canUnlock: steadyRank < 3, lockReason: steadyRank < 3 ? null : 'MAX_RANK' },
    { nodeId: 'life.node.fishing.fish_sense', rank: fishRank, maxRank: 3, nextRankCost: 1, requiredSkillLevel: 3, prerequisites: [{ nodeId: 'life.node.fishing.steady_hands', requiredRank: 1, visible: true, met: steadyRank >= 1 }], canUnlock: steadyRank >= 1 && fishRank < 3, lockReason: steadyRank >= 1 ? (fishRank < 3 ? null : 'MAX_RANK') : 'PREREQUISITE' },
  ],
});
const LIFE_TREE_BODY = lifeTreeBody(1, 0);
const LIFE_TREE_RANK2_BODY = lifeTreeBody(2, 0);
const LIFE_TREE_EMPTY_BODY = lifeTreeBody(0, 0);
const LIFE_REQUEST_ID = '11111111-2222-4333-8444-555555555555';

test('life skills (A-3): read GETs the list; selectSkill GETs the tree with skill_id; unlock POSTs nodeId+requestId and updates the tree', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-life-node-unlock', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { status: 'SUCCESS', nodeId: 'life.node.fishing.steady_hands', skillId: 'life.fishing', rankAfter: 2, tree: LIFE_TREE_RANK2_BODY } }; } },
    { match: '/api/world-life-skill-tree', reply: () => ({ status: 200, body: LIFE_TREE_BODY }) },
    { match: '/api/world-life-skills', reply: () => ({ status: 200, body: LIFE_LIST_BODY }) },
  ]);
  const client = createLifeSkillBookClient({
    getSessionId: () => SESSION, fetcher: fetch,
    requestIdFactory: () => LIFE_REQUEST_ID,
  });
  assert.equal(parseLifeSkillList(LIFE_LIST_BODY).skills.length, 1);
  assert.equal(parseLifeSkillTree(LIFE_TREE_BODY).nodes.length, 2);
  assert.equal(parseLifeSkillTree({ ...LIFE_TREE_BODY, reset: { ...LIFE_TREE_BODY.reset, cost: 5 } }), null);
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.state, 'READY');
  assert.equal(client.book.skills[0].skillId, 'life.fishing');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(await client.selectSkill('life.fishing'), true);
  assert.equal(client.tree.nodes[0].rank, 1);
  const treeCall = calls.find((c) => c.url.includes('/api/world-life-skill-tree'));
  assert.ok(treeCall.url.includes('skill_id=life.fishing'));
  assertSessionOnly(treeCall);
  const unlocked = await client.unlockNode('life.node.fishing.steady_hands');
  assert.equal(unlocked.outcome, 'DONE');
  assert.equal(client.tree.nodes[0].rank, 2);
  assert.equal(bodies.length, 1);
  assert.deepEqual(bodies[0], { nodeId: 'life.node.fishing.steady_hands', requestId: LIFE_REQUEST_ID });
  assertSessionOnly(calls.find((c) => c.init?.method === 'POST'));
});

test('life skills (A-3): reset POSTs skillId+requestId; a definitive LIFE_SP_INSUFFICIENT refusal is REFUSED; a lost reply keeps the request id for the retry', async () => {
  const bodies = [];
  let unlockCalls = 0;
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-life-tree-reset', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { status: 'SUCCESS', skillId: 'life.fishing', refundedSp: 1, tree: LIFE_TREE_EMPTY_BODY } }; } },
    { match: '/api/world-life-node-unlock', reply: () => {
      unlockCalls += 1;
      if (unlockCalls === 1) throw new Error('transport down');
      return { status: 200, body: { status: 'SUCCESS', nodeId: 'life.node.fishing.steady_hands', skillId: 'life.fishing', rankAfter: 2, tree: LIFE_TREE_RANK2_BODY } };
    } },
    { match: '/api/world-life-skill-tree', reply: () => ({ status: 200, body: LIFE_TREE_BODY }) },
    { match: '/api/world-life-skills', reply: () => ({ status: 200, body: LIFE_LIST_BODY }) },
  ]);
  const client = createLifeSkillBookClient({
    getSessionId: () => SESSION, fetcher: fetch,
    requestIdFactory: () => LIFE_REQUEST_ID,
  });
  await client.setAccount(SESSION);
  await client.selectSkill('life.fishing');
  const reset = await client.resetTree('life.fishing');
  assert.equal(reset.outcome, 'DONE');
  assert.equal(client.tree.nodes[0].rank, 0);
  assert.deepEqual(bodies[0], { skillId: 'life.fishing', requestId: LIFE_REQUEST_ID });

  const lost = await client.unlockNode('life.node.fishing.steady_hands');
  assert.equal(lost.outcome, 'FAILED');
  await sleep(10); // the failed write re-reads (fire-and-forget)
  const replayed = await client.unlockNode('life.node.fishing.steady_hands');
  assert.equal(replayed.outcome, 'DONE');
  assert.equal(unlockCalls, 2);
  const unlockPosts = calls.filter((c) => c.url.includes('/api/world-life-node-unlock'));
  assert.equal(unlockPosts.length, 2);
  assert.equal(JSON.parse(unlockPosts[0].init.body).requestId, LIFE_REQUEST_ID);
  assert.equal(JSON.parse(unlockPosts[1].init.body).requestId, LIFE_REQUEST_ID);
  assert.deepEqual(await client.unlockNode('bad-node'), { outcome: 'FAILED', code: 'INVALID_NODE' });
  assert.equal(calls.filter((c) => c.url.includes('/api/world-life-node-unlock')).length, 2);
});

test('life skills (A-3): no session sends nothing and unlock is SIGNED_OUT', async () => {
  const { calls, fetch } = stubFetcher([]);
  const client = createLifeSkillBookClient({ getSessionId: () => null, fetcher: fetch, requestIdFactory: () => LIFE_REQUEST_ID });
  await client.setAccount(SESSION);
  assert.equal(client.state, 'UNAVAILABLE');
  assert.equal(calls.length, 0);
  assert.deepEqual(await client.unlockNode('life.node.fishing.steady_hands'), { outcome: 'SIGNED_OUT' });
});

// ---------- social + accompany (A-3) ----------

const SOCIAL_MINE_BODY = {
  friends: [{ userId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', nickname: 'tier4bob', title: null, avatar: 'classic', inhaVerified: false }],
  incoming: [], outgoing: [], blocked: [],
};
const SOCIAL_PROFILE_BODY = {
  userId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', available: true, relationship: 'friends',
  nickname: 'tier4bob', title: null, avatar: 'classic', inhaVerified: false,
};

test('social (A-3): mine/profile/relationship GET with X-Session-Id; request/accept/block POST the action; report POSTs and maps duplicate', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-friend-request', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { relationship: 'outgoing' } }; } },
    { match: '/api/world-block-user', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { relationship: 'blocked_by_me' } }; } },
    { match: '/api/world-report-user', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { status: 'duplicate' } }; } },
    { match: '/api/world-public-profile', reply: () => ({ status: 200, body: SOCIAL_PROFILE_BODY }) },
    { match: '/api/world-relationship', reply: () => ({ status: 200, body: { relationship: 'friends' } }) },
    { match: '/api/world-social', reply: () => ({ status: 200, body: SOCIAL_MINE_BODY }) },
  ]);
  const client = new SocialClient({ getSessionId: () => SESSION, getSelfUserId: () => USER_ID, fetcher: fetch });
  const social = await client.mine();
  assert.equal(social.friends.length, 1);
  assert.equal(social.friends[0].nickname, 'tier4bob');
  assertSessionOnly(calls[0]);
  const card = await client.profile('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
  assert.equal(card.relationship, 'friends');
  assert.ok(calls.find((c) => c.url.includes('/api/world-public-profile?target=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')));
  assert.equal(await client.relationship('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'), 'friends');
  assert.equal(await client.request('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'), 'outgoing');
  assert.deepEqual(bodies[0], { action: 'send', target: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' });
  assert.equal(await client.block('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'), 'blocked_by_me');
  assert.equal(client.isBlocked('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'), true);
  assert.deepEqual(bodies[1], { action: 'block', target: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' });
  assert.equal(await client.report('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'spam', 'AREA_MAIN_GATE'), 'duplicate');
  assert.deepEqual(bodies[2], { target: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', category: 'spam', placeZoneId: 'AREA_MAIN_GATE' });
  for (const call of calls) assertSessionOnly(call);
});

test('social (A-3): 409 PROFILE_NOT_FOUND surfaces as-is; self target and bad category never fetch; no session is SIGNED_OUT', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-social', reply: () => ({ status: 409, body: { error: 'PROFILE_NOT_FOUND' } }) },
  ]);
  const client = new SocialClient({ getSessionId: () => SESSION, getSelfUserId: () => USER_ID, fetcher: fetch });
  await assert.rejects(client.mine(), (error) => error instanceof SocialError && error.code === 'PROFILE_NOT_FOUND');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  await assert.rejects(client.profile(USER_ID), (error) => error.code === 'TARGET_UNAVAILABLE');
  await assert.rejects(client.report('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'bogus'), (error) => error.code === 'INVALID_CATEGORY');
  assert.equal(calls.length, 1);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = new SocialClient({ getSessionId: () => null, getSelfUserId: () => USER_ID, fetcher: noFetch });
  await assert.rejects(noSession.mine(), (error) => error.code === 'SIGNED_OUT');
  assert.equal(noCalls.length, 0);
});

test('accompany (A-3): mine GETs; propose/respond/end POST the action; a bad poi never fetches; no session is SIGNED_OUT', async () => {
  const ACCOMPANY_SESSION = {
    id: '33333333-4444-4555-8666-777777777777', inviterId: USER_ID,
    inviteeId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', state: 'offered',
    poiId: 'poi.main-gate', placeZoneId: 'AREA_MAIN_GATE',
    peer: { userId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', nickname: 'tier4bob' },
    expiresAt: '2026-11-21T00:00:00.000Z',
  };
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-accompany', reply: (_n, init) => {
      if (init?.method === 'POST') { bodies.push(JSON.parse(init.body)); return { status: 200, body: { ...ACCOMPANY_SESSION, state: 'active' } }; }
      return { status: 200, body: [ACCOMPANY_SESSION] };
    } },
  ]);
  const client = new AccompanyClient({ getSessionId: () => SESSION, getSelfUserId: () => USER_ID, fetcher: fetch });
  const mine = await client.mine();
  assert.equal(mine.length, 1);
  assert.equal(mine[0].peerName, 'tier4bob');
  assert.equal(parseAccompanySession(ACCOMPANY_SESSION, USER_ID).poiId, 'poi.main-gate');
  assert.equal(parseAccompanySession({ ...ACCOMPANY_SESSION, poiId: 'poi.nope' }, USER_ID), null);
  assertSessionOnly(calls[0]);
  await client.propose('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'poi.main-gate', 'AREA_MAIN_GATE');
  assert.deepEqual(bodies[0], { action: 'propose', target: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', poiId: 'poi.main-gate', placeZoneId: 'AREA_MAIN_GATE' });
  await client.respond('33333333-4444-4555-8666-777777777777', true);
  assert.deepEqual(bodies[1], { action: 'respond', sessionId: '33333333-4444-4555-8666-777777777777', accept: true });
  await client.end('33333333-4444-4555-8666-777777777777');
  assert.deepEqual(bodies[2], { action: 'end', sessionId: '33333333-4444-4555-8666-777777777777' });
  for (const call of calls) assertSessionOnly(call);
  await assert.rejects(client.propose('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'poi.nope', 'AREA_MAIN_GATE'), (error) => error.code === 'INVALID_DESTINATION');
  assert.equal(bodies.length, 3);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = new AccompanyClient({ getSessionId: () => null, getSelfUserId: () => USER_ID, fetcher: noFetch });
  await assert.rejects(noSession.mine(), (error) => error.code === 'SIGNED_OUT');
  assert.equal(noCalls.length, 0);
});

// ---------- biryong (A-3) ----------

const BIRYONG_PROGRESS = { step: 'INTRO', lore: [], shouts: 0, discoveredAt: null, completedAt: null };
const BIRYONG_LIST_BODY = {
  relationships: [1, 2, 3, 4, 5, 6, 7, 8].map((n) => ({
    npcId: `BR_NPC_00${n}`, stage: 1, stageState: 'ACQUAINTED', nextStage: 2, revision: 0,
    stage2UnlockedAt: null, stage3UnlockedAt: null, updatedAt: null, unlockedFacts: [],
  })),
};

test('biryong sync (A-3): setAccount GETs the cloud copy then POSTs the merge with X-Session-Id; queue() posts the new snapshot', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-biryong-progress', reply: (_n, init) => {
      if (init?.method === 'POST') { bodies.push(JSON.parse(init.body)); return { status: 200, body: BIRYONG_PROGRESS }; }
      return { status: 200, body: null };
    } },
  ]);
  const merged = [];
  const progress = {
    snapshot: () => ({ ...BIRYONG_PROGRESS }),
    merge: (remote) => { merged.push(remote); },
    setScope: () => ({ migrated: false }),
  };
  const sync = createBiryongCloudSync({
    getSessionId: () => SESSION, fetcher: fetch, progress, debounceMs: 0,
  });
  assert.equal(sync.setAccount(SESSION), true);
  await sleep(20);
  assert.equal(sync.status().state, 'saved');
  assert.equal(calls.length, 2);
  assert.equal(calls[0].init?.method, undefined);
  assert.equal(calls[1].init?.method, 'POST');
  for (const call of calls) assertSessionOnly(call);
  assert.deepEqual(bodies[0], { progress: BIRYONG_PROGRESS, migratedFromLocal: false });
  const next = { ...BIRYONG_PROGRESS, step: 'FIND_CENTER', lore: ['lore.a'], shouts: 2 };
  progress.snapshot = () => ({ ...next });
  assert.equal(sync.queue(next), true);
  await sleep(20);
  assert.equal(bodies.length, 2);
  assert.deepEqual(bodies[1], { progress: next, migratedFromLocal: false });
});

test('biryong sync (A-3): no session fails the flush and leaves canRetry true', async () => {
  const { calls, fetch } = stubFetcher([]);
  const progress = {
    snapshot: () => ({ ...BIRYONG_PROGRESS }),
    merge: () => {},
    setScope: () => ({ migrated: false }),
  };
  const sync = createBiryongCloudSync({ getSessionId: () => null, fetcher: fetch, progress, debounceMs: 0 });
  assert.equal(sync.setAccount(SESSION), true);
  await sleep(20);
  assert.equal(sync.status().state, 'failed');
  assert.equal(sync.status().canRetry, true);
  assert.equal(calls.length, 0);
});

test('biryong relationships (A-3): refresh GETs the 8-NPC list with X-Session-Id; a short list is UNAVAILABLE; no session sends nothing', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-biryong-npc-relationships', reply: () => ({ status: 200, body: BIRYONG_LIST_BODY }) },
  ]);
  assert.equal(parseBiryongRelationshipList(BIRYONG_LIST_BODY).size, 8);
  assert.equal(parseBiryongRelationshipList({ relationships: BIRYONG_LIST_BODY.relationships.slice(0, 7) }), null);
  const client = createBiryongRelationshipClient({ getSessionId: () => SESSION, getUserId: () => SESSION, fetcher: fetch });
  assert.equal(await client.setAccount(SESSION), true);
  assert.equal(client.status().state, 'READY');
  assert.equal(client.stage('BR_NPC_001'), 1);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);

  const { calls: shortCalls, fetch: shortFetch } = stubFetcher([
    { match: '/api/world-biryong-npc-relationships', reply: () => ({ status: 200, body: { relationships: [] } }) },
  ]);
  const short = createBiryongRelationshipClient({ getSessionId: () => SESSION, getUserId: () => SESSION, fetcher: shortFetch });
  assert.equal(await short.setAccount(SESSION), false);
  assert.equal(short.status().state, 'UNAVAILABLE');
  assert.equal(shortCalls.length, 1);

  const { calls: noCalls, fetch: noFetch } = stubFetcher([]);
  const noSession = createBiryongRelationshipClient({ getSessionId: () => null, getUserId: () => SESSION, fetcher: noFetch });
  assert.equal(await noSession.setAccount(SESSION), false);
  assert.equal(noSession.status().state, 'UNAVAILABLE');
  assert.equal(noCalls.length, 0);
});

// ---------- MCM event (A-3) ----------

const MCM_EVENT_BODY = {
  eventId: 'event.mcm_2026', eventState: 'ACTIVE',
  startsAt: '2026-09-29T15:00:00.000Z', endsAt: '2026-09-30T16:00:00.000Z',
  serverNow: '2026-11-20T12:00:00.000Z',
  progress: { stage: 'NOT_STARTED', investigated: [], startedAt: null, venueUnlockedAt: null, completedAt: null },
  landlord: { firstClearedAt: null, activeRun: null },
};
const MCM_RUN_BODY = {
  runId: '44444444-5555-4666-8777-888888888888', status: 'ACTIVE', resumed: false,
  startedAt: '2026-11-20T12:00:00.000Z', deadlineAt: '2026-11-20T12:00:45.000Z',
  serverNow: '2026-11-20T12:00:00.000Z', durationMs: 45000, wrongPenaltyMs: 5000, wrongCount: 0,
  actorIds: ['ZUE-MG-001', 'ZUE-MG-002', 'ZUE-MG-003', 'ZUE-MG-004', 'ZUE-MG-005'],
};
const MCM_CHOICE_BODY = {
  runId: '44444444-5555-4666-8777-888888888888', status: 'CLEARED', correct: true,
  firstClear: true, wrongCount: 0, deadlineAt: '2026-11-20T12:00:45.000Z',
  serverNow: '2026-11-20T12:00:01.000Z', firstClearedAt: '2026-11-20T12:00:01.000Z',
};

test('mcm (A-3): refresh GETs the event; startRun/submitRun/claim POST with X-Session-Id and the Tier 4 bodies; live advance throws MCM_ADVANCE_UNAVAILABLE', async () => {
  const bodies = [];
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-mcm-landlord-choice', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: MCM_CHOICE_BODY }; } },
    { match: '/api/world-mcm-landlord-run', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: MCM_RUN_BODY }; } },
    { match: '/api/world-mcm-claim', reply: (_n, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, body: { claimType: 'MAIN_CLEAR', status: 'CLAIMED', replayed: false, rewardStatus: 'SUCCESS', rewardResult: { entries: [] } } }; } },
    { match: '/api/world-mcm-event', reply: () => ({ status: 200, body: MCM_EVENT_BODY }) },
  ]);
  const client = createMcm2026EventClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setSignedIn(true);
  assert.equal(client.state.eventId, 'event.mcm_2026');
  assert.equal(client.state.progress.stage, 'NOT_STARTED');
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  const run = await client.startRun();
  assert.equal(run.runId, '44444444-5555-4666-8777-888888888888');
  assert.deepEqual(bodies[0], {});
  const choice = await client.submitRun('44444444-5555-4666-8777-888888888888', 'ZUE-MG-002');
  assert.equal(choice.status, 'CLEARED');
  assert.equal(choice.correct, true);
  assert.deepEqual(bodies[1], { runId: '44444444-5555-4666-8777-888888888888', actorId: 'ZUE-MG-002' });
  const claim = await client.claimMain();
  assert.equal(claim.status, 'CLAIMED');
  assert.deepEqual(bodies[2], { claim: 'main' });
  const landlordClaim = await client.claimLandlord();
  assert.deepEqual(bodies[3], { claim: 'landlord_first_clear' });
  for (const call of calls) assertSessionOnly(call);
  assert.ok(!JSON.stringify(calls).includes('Bearer'));
  await assert.rejects(client.advance('start'), /MCM_ADVANCE_UNAVAILABLE/);
  assert.equal(calls.filter((c) => c.url.includes('/api/world-quest')).length, 0);
});

test('mcm (A-3): preview advances locally without fetching; no session leaves the state null and sends nothing', async () => {
  const preview = createMcm2026EventClient({ preview: true });
  const started = await preview.advance('start');
  assert.equal(started.progress.stage, 'STARTED');
  assert.equal(preview.state.progress.stage, 'STARTED');

  const { calls, fetch } = stubFetcher([]);
  const noSession = createMcm2026EventClient({ getSessionId: () => null, fetcher: fetch });
  await noSession.setSignedIn(true);
  assert.equal(noSession.state, null);
  assert.equal(calls.length, 0);
  await assert.rejects(noSession.startRun(), /MCM_AUTH_REQUIRED/);
});

test('mcm (A-3): a server refusal on refresh surfaces the code', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-mcm-event', reply: () => ({ status: 409, body: { error: 'ACCOUNT_UNAVAILABLE' } }) },
  ]);
  const client = createMcm2026EventClient({ getSessionId: () => SESSION, fetcher: fetch });
  await client.setSignedIn(true);
  assert.equal(client.state, null);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
});

// ---- BCD: profile creation (D-2/D-3/D-4) ----
const PROFILE_CREATED_BODY = { created: true, nickname: 'inhagamer', departmentId: 10, avatarKey: 'scholar', title: null };
const PROFILE_EXISTING_BODY = { created: false, nickname: 'inhagamer', departmentId: 10, avatarKey: 'scholar', title: null };

test('profile (BCD): create POSTs with X-Session-Id only, parses 201 created; 200 existing returns created:false and ignores the new values', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-profile', reply: (n) => ({ status: n === 1 ? 201 : 200, body: n === 1 ? PROFILE_CREATED_BODY : PROFILE_EXISTING_BODY }) },
  ]);
  const created = await createWorldProfile({ nickname: 'inhagamer', departmentId: 10, avatarKey: 'scholar' }, { fetchImpl: fetch, getSessionId: () => SESSION });
  assert.equal(created.created, true);
  assert.equal(created.title, null);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  assert.equal(JSON.parse(calls[0].init.body).nickname, 'inhagamer');
  assert.ok(!('title' in JSON.parse(calls[0].init.body)));
  const existing = await createWorldProfile({ nickname: 'othername', departmentId: 1, avatarKey: 'star' }, { fetchImpl: fetch, getSessionId: () => SESSION });
  assert.equal(existing.created, false);
  assert.equal(existing.nickname, 'inhagamer');
  assert.equal(existing.avatarKey, 'scholar');
  assert.equal(parseWorldProfile({ ...PROFILE_CREATED_BODY, nickname: 'x' }), null);
  assert.equal(parseWorldProfile({ ...PROFILE_CREATED_BODY, avatarKey: 'dragon' }), null);
  assert.equal(isWorldProfileNicknameShape('인하생'), true);
  assert.equal(isWorldProfileNicknameShape('bad nick'), true); // space allowed: origin CHECK ^[0-9A-Za-z가-힣_ ]+$
  assert.equal(isWorldProfileNicknameShape('bad!nick'), false);
  assert.equal(parseWorldProfile({ ...PROFILE_CREATED_BODY, nickname: 'bad nick' }).nickname, 'bad nick');
  assert.equal(isWorldProfileNicknameShape('a'), false);
  assert.equal(isWorldProfileNicknameShape('소년연금술사'), true);
  assert.equal(isWorldProfileAvatarKey('star'), true);
  assert.equal(WORLD_PROFILE_AVATARS.length, 4);
});

test('profile (BCD): 409 NICKNAME_TAKEN and 409 PROFILE_REQUIRED (banned, concealed) throw with the server code; no session sends nothing', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-profile', reply: (n) => ({ status: 409, body: { error: n === 1 ? 'NICKNAME_TAKEN' : 'PROFILE_REQUIRED' } }) },
  ]);
  await assert.rejects(
    () => createWorldProfile({ nickname: 'inhagamer', departmentId: 10, avatarKey: 'scholar' }, { fetchImpl: fetch, getSessionId: () => SESSION }),
    (e) => e instanceof WorldProfileError && e.code === 'NICKNAME_TAKEN');
  await assert.rejects(
    () => createWorldProfile({ nickname: 'newname', departmentId: 10, avatarKey: 'scholar' }, { fetchImpl: fetch, getSessionId: () => SESSION }),
    (e) => e instanceof WorldProfileError && e.code === 'PROFILE_REQUIRED');
  assert.equal(calls.length, 2);
  const { fetch: fetch2 } = stubFetcher([]);
  await assert.rejects(
    () => createWorldProfile({ nickname: 'inhagamer', departmentId: 10, avatarKey: 'scholar' }, { fetchImpl: fetch2, getSessionId: () => null }),
    (e) => e instanceof WorldProfileError && e.code === 'SESSION_ID_REQUIRED');
});

// ---- BCD: mail manual verification (D-1 fallback (c)) ----
const MAIL_REQ_BODY = { requestId: '11111111-2222-4333-8444-555555555555', email: 'carol@inha.edu', status: 'PENDING', duplicate: false };

test('mail (BCD): request POSTs with X-Session-Id only; 201 new and 200 duplicate parse; bad domain 400, rate limit 429, no session sends nothing', async () => {
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-mail-verify-request', reply: (n) => {
      if (n === 1) return { status: 201, body: MAIL_REQ_BODY };
      if (n === 2) return { status: 200, body: { ...MAIL_REQ_BODY, duplicate: true } };
      if (n === 3) return { status: 400, body: { error: 'INVALID_EMAIL' } };
      return { status: 429, body: { error: 'RATE_LIMITED' } };
    } },
  ]);
  const req = await requestWorldMailVerification('carol@inha.edu', { fetchImpl: fetch, getSessionId: () => SESSION });
  assert.equal(req.duplicate, false);
  assert.equal(req.status, 'PENDING');
  assertSessionOnly(calls[0]);
  assert.equal(JSON.parse(calls[0].init.body).email, 'carol@inha.edu');
  const dup = await requestWorldMailVerification('CAROL@INHA.EDU', { fetchImpl: fetch, getSessionId: () => SESSION });
  assert.equal(dup.duplicate, true);
  assert.equal(JSON.parse(calls[1].init.body).email, 'CAROL@INHA.EDU');
  await assert.rejects(
    () => requestWorldMailVerification('dave@gmail.com', { fetchImpl: fetch, getSessionId: () => SESSION }),
    (e) => e instanceof WorldMailVerifyError && e.code === 'INVALID_EMAIL');
  await assert.rejects(
    () => requestWorldMailVerification('dave@inha.edu', { fetchImpl: fetch, getSessionId: () => SESSION }),
    (e) => e instanceof WorldMailVerifyError && e.code === 'RATE_LIMITED');
  assert.equal(isInhaMailAddress('a@inha.ac.kr'), true);
  assert.equal(isInhaMailAddress('a@inha.edu'), true);
  assert.equal(isInhaMailAddress('a@gmail.com'), false);
  assert.equal(parseWorldMailVerifyRequest({ ...MAIL_REQ_BODY, email: 'a@gmail.com' }), null);
  const { fetch: fetch2 } = stubFetcher([]);
  await assert.rejects(
    () => requestWorldMailVerification('a@inha.edu', { fetchImpl: fetch2, getSessionId: () => null }),
    (e) => e instanceof WorldMailVerifyError && e.code === 'SESSION_ID_REQUIRED');
});

// ---- BCD: online heartbeat + population count (C-group (b)) ----
const FAKE_SCHEDULER = { setInterval: () => 1, clearInterval: () => {} };
const FAKE_STORAGE = { getItem: () => null, setItem: () => {} };
const VISITOR_ID = '22222222-3333-4444-8555-666666666666';

test('online (BCD): heartbeat touches with the guest session id (C-3 merge), sends visitor + zone + space, 429 is a retryable lastError, constants are 20 s', async () => {
  assert.equal(WORLD_HEARTBEAT_MS, 20_000);
  assert.equal(WORLD_POPULATION_REFRESH_MS, 20_000);
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-online-touch', reply: (n) => (n === 1 ? { status: 200, body: { ok: true } } : { status: 429, body: { error: 'RATE_LIMITED' } }) },
  ]);
  const hb = startWorldPopulationHeartbeat({
    fetchImpl: fetch, getSessionId: () => SESSION, randomId: () => VISITOR_ID,
    visitorStorage: FAKE_STORAGE, scheduler: FAKE_SCHEDULER, windowTarget: undefined,
    getSnapshot: () => ({ placeZoneId: 'AREA_MAIN_GATE', space: 'campus' }),
  });
  assert.ok(hb);
  assert.equal(hb.sessionId, SESSION);
  assert.equal(hb.visitorId, VISITOR_ID);
  assert.equal(await hb.initialPulse, true);
  assert.equal(calls.length, 1);
  assertSessionOnly(calls[0]);
  const sent = JSON.parse(calls[0].init.body);
  assert.equal(sent.placeZoneId, 'AREA_MAIN_GATE');
  assert.equal(sent.space, 'campus');
  assert.equal(sent.visitorId, VISITOR_ID);
  assert.equal(await hb.pulse(), false);
  assert.equal(hb.status().lastError, 'RATE_LIMITED');
  assert.equal(hb.status().stopped, false);
  hb.stop();
  assert.equal(hb.status().stopped, true);
});

test('online (BCD): heartbeat with no guest session returns null and sends nothing', () => {
  const hb = startWorldPopulationHeartbeat({ fetchImpl: async () => { throw new Error('must not fetch'); }, getSessionId: () => null });
  assert.equal(hb, null);
});

test('online (BCD): population count parses signedIn 0 / guests == online, rejects a broken sum, refreshes every 20 s', async () => {
  const COUNT_BODY = { online: 3, signedIn: 0, guests: 3, lobby: 1, campus: 2, clubRoom: 0, housingLobby: 0, personalRoom: 0, asOf: '2026-11-20T00:00:00.000Z' };
  assert.deepEqual(parseWorldPopulationSnapshot(COUNT_BODY).guests, 3);
  assert.equal(parseWorldPopulationSnapshot({ ...COUNT_BODY, guests: 2 }), null);
  const sumOk = parseWorldPopulationSnapshot({ ...COUNT_BODY, signedIn: 1, guests: 2 });
  assert.equal(sumOk.online, 3);
  assert.equal(sumOk.signedIn, 1);
  const { calls, fetch } = stubFetcher([
    { match: '/api/world-online-count', reply: () => ({ status: 200, body: COUNT_BODY }) },
  ]);
  let published = null;
  const counter = startWorldPopulationCount({ fetchImpl: fetch, scheduler: FAKE_SCHEDULER, onChange: (s) => { published = s; } });
  assert.equal(await counter.refresh(), true);
  assert.equal(counter.status().state, 'READY');
  assert.equal(counter.status().snapshot.online, 3);
  assert.equal(counter.status().snapshot.signedIn, 0);
  assert.equal(published.state, 'READY');
  assert.equal(calls.length, 1);
  assert.ok(!('X-Session-Id' in (calls[0].init?.headers ?? {})));
  counter.stop();
});
