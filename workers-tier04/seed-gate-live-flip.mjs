// Live jeongseok-only gate flip (SEED-GATE-ROLLOUT.md step 2, split decision G-3/C-4).
// Flips ONLY the 2 jeongseok rows (gate_policy + pass_catalog) to ACTIVE.
// The 3 cooking rows (recipe_catalog, cooking_station, grilled_carp) stay
// COMING_SOON. The flip is NOT restored: ACTIVE is the decided live state.
// Modes: gates | flip-jeongseok (then print the rows).
// TEST_OWNER_URL env must be the LIVE (promoted main) owner URL.
import { neon } from '@neondatabase/serverless';
const owner = neon(process.env.TEST_OWNER_URL);
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
} else if (mode === 'flip-jeongseok') {
  await owner`update private.world_jeongseok_gate_policy set status = 'ACTIVE'`;
  await owner`update private.world_jeongseok_pass_catalog set status = 'ACTIVE' where pass_type = 'jeongseok.visitor.day'`;
  await gates();
} else {
  console.error('usage: node seed-gate-live-flip.mjs gates|flip-jeongseok');
  process.exit(2);
}
