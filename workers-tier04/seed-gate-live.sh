#!/usr/bin/env bash
# Live jeongseok-only gate activation + smoke via inhagame.app (Worker route).
# DECISIONS.md G-3/C-4: jeongseok ACTIVE, cooking stays COMING_SOON.
# Usage: TEST_OWNER_URL must be the LIVE owner URL (run via run-seed-gate-live.py).
# The flip is NOT restored. Fixtures are torn down at the end.
set -u
BASE="https://inhagame.app"
SG="e5000000-0000-4000-8000-000000000005" # seed-gate user (station + carp x3, wallet 500)
pass=0; fail=0
ok() { if [ "$2" = "True" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
t() {
  local name="$1" want="$2" method="$3" path="$4" sess="$5" body="$6"
  local code out
  out=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json" -H "X-Session-Id: $sess" ${body:+--data "$body"} 2>&1)
  code=$(echo "$out" | tail -n 1)
  local resp=$(echo "$out" | head -n -1 | head -c 300)
  if [ "$code" = "$want" ]; then pass=$((pass+1)); echo "PASS $name -> $code $resp"; else fail=$((fail+1)); echo "FAIL $name -> got $code want $want $resp"; fi
}
gates_json() { node seed-gate-live-flip.mjs gates; }
jeongseok_active() { gates_json | python3 -c "import sys,json;rows={r['row']:r['status'] for r in json.load(sys.stdin)};print(rows.get('gate_policy')=='ACTIVE' and rows.get('pass_catalog')=='ACTIVE' and rows.get('recipe_catalog')=='COMING_SOON' and rows.get('item_cooking_station')=='COMING_SOON' and rows.get('item_grilled_carp')=='COMING_SOON')"; }
all_closed() { gates_json | python3 -c "import sys,json;rows=json.load(sys.stdin);print(len(rows)==5 and all(r['status']=='COMING_SOON' for r in rows))"; }

echo "== gates before =="
gates_json
ok "gates before: all 5 COMING_SOON" "$(all_closed)"

echo "== setup fixtures =="
node seed-gate-fixtures.mjs setup

echo "== closed-gate baseline via inhagame.app =="
t "jeongseok access closed 200" 200 GET /api/world-jeongseok-access "$SG" ""
t "jeongseok purchase closed 409" 409 POST /api/world-jeongseok-pass "$SG" '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-live-0"}'
t "cooking closed 409" 409 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000001"}'

echo "== flip jeongseok-only ACTIVE (live state, NOT restored) =="
node seed-gate-live-flip.mjs flip-jeongseok
ok "gates after flip: jeongseok ACTIVE, cooking COMING_SOON" "$(jeongseok_active)"

echo "== jeongseok smoke via inhagame.app =="
JS_ACCESS=$(curl -s "$BASE/api/world-jeongseok-access" -H "X-Session-Id: $SG")
JS_ACCESS_FLAGS=$(echo "$JS_ACCESS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('gateStatus')=='ACTIVE' and d.get('decision')=='NEEDS_PASS' and d.get('offer',{}).get('price')==100)")
ok "jeongseok access ACTIVE, NEEDS_PASS, offer 100 coins" "$JS_ACCESS_FLAGS"
JS_BUY=$(curl -s -X POST "$BASE/api/world-jeongseok-pass" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-live-1"}')
JS_BUY_FLAGS=$(echo "$JS_BUY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status')=='SUCCESS' and d.get('price')==100 and d.get('balanceBefore')==500 and d.get('balanceAfter')==400 and d.get('access',{}).get('decision')=='GRANTED' and d.get('access',{}).get('via')=='VISITOR_PASS')")
ok "jeongseok purchase 100 coins, 500->400, GRANTED via VISITOR_PASS" "$JS_BUY_FLAGS"
JS_BUY_ID=$(echo "$JS_BUY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('purchaseId',''))")
JS_REPLAY=$(curl -s -X POST "$BASE/api/world-jeongseok-pass" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-live-1"}')
JS_REPLAY_FLAGS=$(echo "$JS_REPLAY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status')=='ALREADY_PROCESSED' and d.get('purchaseId')=='$JS_BUY_ID' and d.get('balanceAfter')==400)")
ok "jeongseok purchase replay same receipt, no double charge" "$JS_REPLAY_FLAGS"
t "jeongseok re-purchase while active 409" 409 POST /api/world-jeongseok-pass "$SG" '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-live-2"}'
t "cooking still closed 409 (split decision)" 409 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000002"}'

echo "== teardown fixtures (test purchase rows removed; gate stays ACTIVE) =="
node seed-gate-fixtures.mjs teardown
echo "== gates after teardown (must still be jeongseok ACTIVE) =="
gates_json
ok "gates final: jeongseok ACTIVE, cooking COMING_SOON" "$(jeongseok_active)"
echo "seed-gate-live: pass=$pass fail=$fail"
[ "$fail" = "0" ]
