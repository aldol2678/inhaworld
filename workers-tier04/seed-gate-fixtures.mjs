// Seed-gate isolation verification fixtures (SEED-GATE-ROLLOUT.md step 0).
// Runs against the BCD test branch only (TEST_OWNER_URL env). Never live.
// Modes: gates (print the 5 gate rows as JSON), flip <ACTIVE|COMING_SOON>
// (one transaction, then print the rows), setup, teardown.
import { neon } from '@neondatabase/serverless';
const owner = neon(process.env.TEST_OWNER_URL);
const SG = 'e5000000-0000-4000-8000-000000000005'; // seed-gate user (station + carp x3)
const SG2 = 'e5000000-0000-4000-8000-000000000006'; // seed-gate user 2 (carp x1, NO station)
const USERS = [SG, SG2];
const mode = process.argv[2];

async function gates() {
  const rows = await owner([`select 'gate_policy' as row, status from private.world_jeongseok_gate_policy
    union all select 'pass_catalog', status from private.world_jeongseok_pass_catalog where pass_type = 'jeongseok.visitor.day'
    union all select 'recipe_catalog', status from private.world_recipe_catalog where recipe_id = 'recipe.carp_grill'
    union all select 'item_cooking_station', status from private.world_item_catalog where item_id = 'furniture.cooking_station'
    union all select 'item_grilled_carp', status from private.world_item_catalog where item_id = 'consumable.grilled_carp'
    order by 1`]);
  console.log(JSON.stringify(rows));
}

if (mode === 'gates') {
  await gates();
} else if (mode === 'flip') {
  const target = process.argv[3];
  if (!['ACTIVE', 'COMING_SOON'].includes(target)) { console.error('flip target must be ACTIVE or COMING_SOON'); process.exit(2); }
  // Four sequential updates (the Neon HTTP driver sends one statement per
  // call; the caller re-reads all five rows afterwards, and the shell
  // script always flips back even when a curl case fails).
  await owner`update private.world_jeongseok_gate_policy set status = ${target}`;
  await owner`update private.world_jeongseok_pass_catalog set status = ${target} where pass_type = 'jeongseok.visitor.day'`;
  await owner`update private.world_recipe_catalog set status = ${target} where recipe_id = 'recipe.carp_grill'`;
  await owner`update private.world_item_catalog set status = ${target} where item_id in ('furniture.cooking_station', 'consumable.grilled_carp')`;
  await gates();
} else if (mode === 'setup') {
  await owner`insert into public.sessions (id, nickname) values (${SG}, 'seedgate'), (${SG2}, 'seedgate2') on conflict (id) do nothing`;
  await owner`insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values (${SG}, 'seedgate', 10, null, false, '2026-11-01T00:00:00Z'), (${SG2}, 'seedgate2', 10, null, false, '2026-11-01T00:00:00Z') on conflict (user_id) do nothing`;
  await owner`insert into private.world_wallets (user_id, currency_id, balance) values (${SG}, 'currency.induck_coin', 500), (${SG2}, 'currency.induck_coin', 500) on conflict (user_id, currency_id) do nothing`;
  await owner`insert into private.world_item_grants (grant_id, user_id, item_id, result, quantity_requested, quantity_before, quantity_granted, quantity_after, source_type, source_ref) values ('f5000000-0000-4000-8000-000000000001', ${SG}, 'material.fish_carp', 'GRANTED', 3, 0, 3, 3, 'SYSTEM', 'seed-gate'), ('f5000000-0000-4000-8000-000000000002', ${SG}, 'furniture.cooking_station', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'seed-gate'), ('f5000000-0000-4000-8000-000000000003', ${SG2}, 'material.fish_carp', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'seed-gate') on conflict (grant_id) do nothing`;
  await owner`insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id, acquired_at, updated_at) values (${SG}, 'material.fish_carp', 3, 'test', 'seed-gate', 'f5000000-0000-4000-8000-000000000001', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${SG}, 'furniture.cooking_station', 1, 'test', 'seed-gate', 'f5000000-0000-4000-8000-000000000002', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${SG2}, 'material.fish_carp', 1, 'test', 'seed-gate', 'f5000000-0000-4000-8000-000000000003', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z') on conflict do nothing`;
  console.log('seed-gate fixtures setup done');
} else if (mode === 'teardown') {
  // Two append-only triggers block DELETE (not just UPDATE): disable them
  // for the owner cleanup, then re-enable immediately. Every other
  // append-only trigger in this schema is UPDATE-only, so plain DELETEs
  // work there. The room rows go before the profile delete (layouts and
  // presence reference the room).
  await owner`alter table private.world_jeongseok_pass_purchases disable trigger world_jeongseok_pass_purchases_append_only`;
  await owner`alter table private.world_recipe_receipts disable trigger world_recipe_receipts_append_only`;
  await owner`delete from private.world_jeongseok_pass_purchases where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_jeongseok_pass_entitlements where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_recipe_receipts where user_id = any(${USERS}::uuid[])`;
  await owner`alter table private.world_jeongseok_pass_purchases enable trigger world_jeongseok_pass_purchases_append_only`;
  await owner`alter table private.world_recipe_receipts enable trigger world_recipe_receipts_append_only`;
  await owner`delete from private.world_room_knocks where visitor_user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_room_owner_presence where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_room_layouts where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await owner`delete from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_purchase_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_inventory_mutation_entries where mutation_id in (select mutation_id from private.world_inventory_mutations where user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_inventory_mutations where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_item_consumptions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_currency_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.profiles where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_wallets where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_items where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_item_grants where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.sessions where id = any(${USERS}::text[])`;
  const left = await owner([`select (select count(*) from public.sessions where id = any(array['${USERS.join("','")}'])) + (select count(*) from public.profiles where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_jeongseok_pass_purchases where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_recipe_receipts where user_id = any(array['${USERS.join("','")}']::uuid[])) as n`]);
  console.log('seed-gate fixtures teardown done, leftover=' + left[0].n);
} else {
  console.error('usage: node seed-gate-fixtures.mjs gates|flip <ACTIVE|COMING_SOON>|setup|teardown');
  process.exit(2);
}
