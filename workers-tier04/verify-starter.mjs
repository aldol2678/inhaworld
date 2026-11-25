// Verify the housing starter grant on the staging branch (tier4-bcd-test).
// Runs ONLY against the branch named by DATABASE_URL (set by stage-starter.py).
// Fixtures use isolated a6000000-... UUIDs and are deleted afterwards.
// Prints PASS/FAIL lines only; exits non-zero if any check fails.
import { neon } from '@neondatabase/serverless';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL env required'); process.exit(2); }
const sql = neon(url);

const F1 = 'a6000000-0000-4000-8000-000000000001'; // fresh user
const F2 = 'a6000000-0000-4000-8000-000000000002'; // existing room owner
const STRANGER = 'a6000000-0000-4000-8000-000000000009';
const STARTER = [
  'furniture.dorm_single_sofa',
  'furniture.dorm_side_table_low',
  'furniture.dorm_bookshelf_slim',
  'furniture.dorm_plant_medium',
  'furniture.dorm_monitor',
  'furniture.dorm_trophy_shelf',
  'furniture.study_books_set',
];
// Placements validated against validate_world_room_furniture_v1:
// floor items avoid exit (-0.9..0.9, -4.2..-2.25) and fixed furniture;
// desk items stay in 2.05..3.85 x 1.375..2.025 and clear the laptop zone.
const PLACEMENT = [
  { id: 'f1000000-0000-4000-8000-000000000001', itemId: 'furniture.dorm_single_sofa', surface: 'floor', x: -3, z: -3, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000002', itemId: 'furniture.dorm_side_table_low', surface: 'floor', x: 1.5, z: -3, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000003', itemId: 'furniture.dorm_bookshelf_slim', surface: 'floor', x: 5.5, z: -3, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000004', itemId: 'furniture.dorm_plant_medium', surface: 'floor', x: -5.5, z: -3, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000005', itemId: 'furniture.dorm_monitor', surface: 'desk', x: 2.5, z: 1.5, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000006', itemId: 'furniture.dorm_trophy_shelf', surface: 'floor', x: 0, z: 3, yaw: 0 },
  { id: 'f1000000-0000-4000-8000-000000000007', itemId: 'furniture.study_books_set', surface: 'desk', x: 2.5, z: 1.75, yaw: 0 },
];

const results = [];
const check = (name, ok, note = '') => {
  results.push({ name, ok: !!ok, note: String(note).slice(0, 300) });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${note ? ' — ' + note : ''}`);
};
const one = async (stmt) => (await sql([stmt]))[0];
const count = async (stmt) => Number((await one(stmt)).c);

let room1 = null;
try {
  // V1: migration state
  check('reward definition ACTIVE v1',
    (await count(`select count(*) c from private.world_reward_definitions where reward_id='reward.housing.starter_f0' and status='ACTIVE' and version=1`)) === 1);
  check('reward grants 7 ITEM x1',
    (await count(`select count(*) c from private.world_reward_grants where reward_id='reward.housing.starter_f0' and grant_type='ITEM' and amount=1`)) === 7);
  check('no starter reward before test (fresh user has 0 items)',
    (await count(`select count(*) c from private.world_player_items where user_id='${F1}'`)) === 0);

  // V2: fresh user — first room entry grants all 7
  // NOTE: save needs a non-banned profiles row (world_room_access_v1: guests
  // never enter a personal room); ensure alone is guest-open. The 11:22 live
  // flow creates the profile before saving, so the fixture does the same.
  await sql([`insert into public.sessions (id, nickname) values ('${F1}', 'starter1') on conflict (id) do nothing`]);
  await sql([`insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values ('${F1}'::uuid, 'starter1', 10, null, false, '2026-11-01T00:00:00Z') on conflict (user_id) do nothing`]);
  const ensured = await one(`select public.get_or_create_my_personal_room_v1('${F1}'::uuid) as room`);
  room1 = ensured.room?.roomId ?? ensured.room?.roomid ?? null;
  // neon driver may return jsonb as object or string; normalize
  if (typeof room1 !== 'string') {
    const raw = await one(`select public.get_or_create_my_personal_room_v1('${F1}'::uuid)::text as room`);
    room1 = JSON.parse(raw.room).roomId;
  }
  check('fresh user room created', typeof room1 === 'string' && room1.length === 36, room1);
  const owned1 = await sql([`select item_id from private.world_player_items where user_id='${F1}' order by item_id`]);
  check('fresh user owns all 7 starter items',
    owned1.length === 7 && STARTER.every((s) => owned1.some((r) => r.item_id === s)),
    `owned=${owned1.length}`);
  const tx1 = await count(`select count(*) c from private.world_reward_transactions where user_id='${F1}' and reward_id='reward.housing.starter_f0'`);
  check('exactly 1 reward transaction for fresh user', tx1 === 1, `tx=${tx1}`);
  const entries1 = await count(`select count(*) c from private.world_reward_transaction_entries e join private.world_reward_transactions t on t.reward_transaction_id=e.reward_transaction_id where t.user_id='${F1}' and t.reward_id='reward.housing.starter_f0' and e.status='GRANTED'`);
  check('7 granted entries', entries1 === 7, `entries=${entries1}`);

  // V3: place all 7 + save succeeds, revision 0 -> 1
  const saved = await one(`select public.save_my_room_furniture_v1('${F1}'::uuid, '${room1}'::uuid, 0, '${JSON.stringify(PLACEMENT)}'::jsonb) as snap`);
  const snap = typeof saved.snap === 'string' ? JSON.parse(saved.snap) : saved.snap;
  check('save all 7 starter items, revision 0 -> 1', snap.revision === 1 && snap.objects?.length === 7,
    `revision=${snap.revision} objects=${snap.objects?.length}`);
  const readBack = await one(`select public.get_world_room_furniture_v1('${F1}'::uuid, '${room1}'::uuid) as snap`);
  const rb = typeof readBack.snap === 'string' ? JSON.parse(readBack.snap) : readBack.snap;
  check('read-back revision 1 with 7 objects', rb.revision === 1 && rb.objects?.length === 7);

  // V4: re-entry grants nothing extra
  await one(`select public.get_or_create_my_personal_room_v1('${F1}'::uuid) as room`);
  check('re-entry: still 7 items (no duplicate grant)',
    (await count(`select count(*) c from private.world_player_items where user_id='${F1}'`)) === 7);
  check('re-entry: still 1 reward transaction',
    (await count(`select count(*) c from private.world_reward_transactions where user_id='${F1}' and reward_id='reward.housing.starter_f0'`)) === 1);

  // V5: existing room owner gets the grant retroactively on next entry
  await sql([`insert into public.sessions (id, nickname) values ('${F2}', 'starter2') on conflict (id) do nothing`]);
  await sql([`insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values ('${F2}'::uuid, 'starter2', 10, null, false, '2026-11-01T00:00:00Z') on conflict (user_id) do nothing`]);
  await sql([`insert into public.world_player_rooms (owner_user_id, room_type, visibility) values ('${F2}'::uuid, 'DORM_1_BASIC', 'friends') on conflict (owner_user_id) do nothing`]);
  check('existing owner starts with 0 items',
    (await count(`select count(*) c from private.world_player_items where user_id='${F2}'`)) === 0);
  await one(`select public.get_or_create_my_personal_room_v1('${F2}'::uuid) as room`);
  const owned2 = await sql([`select item_id from private.world_player_items where user_id='${F2}' order by item_id`]);
  check('existing owner retroactively owns all 7',
    owned2.length === 7 && STARTER.every((s) => owned2.some((r) => r.item_id === s)),
    `owned=${owned2.length}`);

  // V6: unknown session still refused (hook did not weaken the guard)
  let threw = '';
  try {
    await one(`select public.get_or_create_my_personal_room_v1('${STRANGER}'::uuid) as room`);
  } catch (e) { threw = String(e?.message ?? e); }
  check('unknown session refused ACCOUNT_UNAVAILABLE', threw.includes('ACCOUNT_UNAVAILABLE'), threw.slice(0, 120));
} catch (e) {
  check('verification sequence completed without unexpected error', false, String(e?.message ?? e).slice(0, 300));
} finally {
  // Cleanup fixtures (best effort; branch is disposable)
  const users = `'${F1}','${F2}'`;
  const steps = [
    `delete from private.world_room_layouts where room_id in (select id from public.world_player_rooms where owner_user_id in (${users}))`,
    `delete from public.world_player_rooms where owner_user_id in (${users})`,
    `delete from private.world_player_items where user_id in (${users})`,
    `delete from private.world_item_grants where user_id in (${users})`,
    `delete from private.world_reward_transaction_entries where reward_transaction_id in (select reward_transaction_id from private.world_reward_transactions where user_id in (${users}))`,
    `delete from private.world_reward_transactions where user_id in (${users})`,
    `delete from public.profiles where user_id in (${users})`,
    `delete from public.sessions where id in (${users})`,
  ];
  for (const s of steps) {
    try { await sql([s]); } catch (e) { console.log(`cleanup note: ${String(e?.message ?? e).slice(0, 120)}`); }
  }
  const left = await count(`select count(*) c from private.world_player_items where user_id in (${users})`);
  check('fixtures cleaned up (0 items left)', left === 0, `left=${left}`);
}

const failed = results.filter((r) => !r.ok).length;
console.log(`verify-starter: ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 4 : 0);
