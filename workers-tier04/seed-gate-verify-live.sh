#!/usr/bin/env bash
# Seed-gate isolation verification (SEED-GATE-ROLLOUT.md step 0).
# BCD test branch + BCD Worker ONLY. Never touches live.
# Usage: TEST_OWNER_URL must be set in the environment (same as run-curl-bcd.py).
# Prints one line per case plus a summary; exits non-zero on any failure.
# NOTE (G-3, split): the isolation flip covers BOTH jeongseok and cooking so
# the code paths are verified, but the recorded switch decision is
# jeongseok-only — cooking stays on hold (no station acquisition path, and
# fishing is not implemented in the game). Nothing here switches live.
set -u
BASE="https://inha-world-tier04.aldol-lab.workers.dev"
SG="e5000000-0000-4000-8000-000000000005" # seed-gate user (station + carp x3)
SG2="e5000000-0000-4000-8000-000000000006" # seed-gate user 2 (carp x1, NO station)
pass=0; fail=0
ok() { # ok NAME CONDITION
  if [ "$2" = "True" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi
}
t() { # t NAME WANT_HTTP METHOD PATH SESSION BODY
  local name="$1" want="$2" method="$3" path="$4" sess="$5" body="$6"
  local code out
  out=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json" -H "X-Session-Id: $sess" ${body:+--data "$body"} 2>&1)
  code=$(echo "$out" | tail -n 1)
  local resp=$(echo "$out" | head -n -1 | head -c 300)
  if [ "$code" = "$want" ]; then pass=$((pass+1)); echo "PASS $name -> $code $resp"; else fail=$((fail+1)); echo "FAIL $name -> got $code want $want $resp"; fi
}
gates_json() { node seed-gate-fixtures.mjs gates; }
all_status() { # all_status WANT -> True when all 5 rows have that status
  gates_json | python3 -c "import sys,json;rows=json.load(sys.stdin);print(len(rows)==5 and all(r['status']=='$1' for r in rows))"
}

echo "== 0-1 gate values before =="
GATES_BEFORE=$(gates_json)
echo "$GATES_BEFORE"
ok "gates before: all 5 COMING_SOON" "$(all_status COMING_SOON)"

echo "== setup fixtures =="
node seed-gate-fixtures.mjs setup

echo "== place the cooking station in SG's room (cook requires the station on the room floor, not just in inventory) =="
SG_ROOM=$(curl -s -X POST "$BASE/api/world-personal-room" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"action":"ensure"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('roomId',''))")
echo "seed room: $SG_ROOM"
SG_STATION_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-room-furniture" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data "{\"roomId\":\"$SG_ROOM\",\"revision\":0,\"objects\":[{\"id\":\"f5000000-0000-4000-8000-000000000021\",\"itemId\":\"furniture.cooking_station\",\"surface\":\"floor\",\"x\":0,\"z\":0,\"yaw\":0}]}")
if [ "$SG_STATION_CODE" = "200" ] && [ -n "$SG_ROOM" ]; then pass=$((pass+1)); echo "PASS seed room station placed on floor -> $SG_STATION_CODE"; else fail=$((fail+1)); echo "FAIL seed room station placed -> $SG_STATION_CODE room=$SG_ROOM"; fi

echo "== closed-gate baseline (before flip) =="
t "jeongseok access closed 200" 200 GET /api/world-jeongseok-access "$SG" ""
t "jeongseok purchase closed 409" 409 POST /api/world-jeongseok-pass "$SG" '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-0"}'
t "cooking closed 409" 409 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000001"}'

echo "== 0-2 flip to ACTIVE (isolation only) =="
GATES_ACTIVE=$(node seed-gate-fixtures.mjs flip ACTIVE)
echo "$GATES_ACTIVE"
ok "gates after flip: all 5 ACTIVE" "$(all_status ACTIVE)"

echo "== 0-3 curl re-measure (gates ACTIVE) =="
JS_ACCESS=$(curl -s "$BASE/api/world-jeongseok-access" -H "X-Session-Id: $SG")
JS_ACCESS_FLAGS=$(echo "$JS_ACCESS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('gateStatus')=='ACTIVE' and d.get('decision')=='NEEDS_PASS' and d.get('offer',{}).get('price')==100)")
ok "jeongseok access ACTIVE, NEEDS_PASS, offer 100 coins" "$JS_ACCESS_FLAGS"
JS_BUY=$(curl -s -X POST "$BASE/api/world-jeongseok-pass" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-1"}')
JS_BUY_FLAGS=$(echo "$JS_BUY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status')=='SUCCESS' and d.get('price')==100 and d.get('balanceBefore')==500 and d.get('balanceAfter')==400 and d.get('access',{}).get('decision')=='GRANTED' and d.get('access',{}).get('via')=='VISITOR_PASS')")
ok "jeongseok purchase 100 coins, 500->400, GRANTED via VISITOR_PASS" "$JS_BUY_FLAGS"
JS_BUY_ID=$(echo "$JS_BUY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('purchaseId',''))")
JS_REPLAY=$(curl -s -X POST "$BASE/api/world-jeongseok-pass" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-1"}')
JS_REPLAY_FLAGS=$(echo "$JS_REPLAY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status')=='ALREADY_PROCESSED' and d.get('purchaseId')=='$JS_BUY_ID' and d.get('balanceAfter')==400)")
ok "jeongseok purchase replay same receipt, no double charge" "$JS_REPLAY_FLAGS"
t "jeongseok re-purchase while active 409" 409 POST /api/world-jeongseok-pass "$SG" '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-2"}'
COOK1=$(curl -s -X POST "$BASE/api/world-cooking" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000011"}')
COOK1_FLAGS=$(echo "$COOK1" | python3 -c "import sys,json;d=json.load(sys.stdin);e=(d.get('inventory') or {}).get('entries') or [];print(d.get('status')=='SUCCESS' and len(e)==2 and e[0].get('itemId')=='material.fish_carp' and e[0].get('quantityAfter')==2 and e[1].get('itemId')=='consumable.grilled_carp' and e[1].get('quantityAfter')==1)")
ok "cooking success: carp 3->2, grilled carp 0->1" "$COOK1_FLAGS"
COOK1_REPLAY=$(curl -s -X POST "$BASE/api/world-cooking" -H "Content-Type: application/json" -H "X-Session-Id: $SG" --data '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000011"}')
# The replay returns the stored receipt verbatim (its inventory.status is
# the original 'SUCCESS', not 'ALREADY_PROCESSED' — that status only
# appears on mutation-level replays). Assert full receipt equality.
echo "$COOK1" > /tmp/cook1.json; echo "$COOK1_REPLAY" > /tmp/cook1r.json
COOK1_REPLAY_FLAGS=$(python3 -c "import json;print(json.load(open('/tmp/cook1.json'))==json.load(open('/tmp/cook1r.json')))")
ok "cooking replay returns the identical receipt, no double consume" "$COOK1_REPLAY_FLAGS"
t "cooking second success" 200 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000012"}'
t "cooking third success (carp now 0)" 200 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000013"}'
t "cooking insufficient ingredient 409" 409 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000014"}'
t "cooking no station 403" 403 POST /api/world-cooking "$SG2" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000015"}'

echo "== 0-4 restore to COMING_SOON =="
GATES_RESTORED=$(node seed-gate-fixtures.mjs flip COMING_SOON)
echo "$GATES_RESTORED"
ok "gates after restore: all 5 COMING_SOON" "$(all_status COMING_SOON)"

echo "== closed-gate re-check (after restore) =="
t "jeongseok access restored 200" 200 GET /api/world-jeongseok-access "$SG" ""
t "jeongseok purchase restored 409" 409 POST /api/world-jeongseok-pass "$SG" '{"passType":"jeongseok.visitor.day","idempotencyKey":"seed-js-9"}'
t "cooking restored 409" 409 POST /api/world-cooking "$SG" '{"recipeId":"recipe.carp_grill","requestId":"f5000000-0000-4000-8000-000000000019"}'
JS_ACCESS_AFTER=$(curl -s "$BASE/api/world-jeongseok-access" -H "X-Session-Id: $SG")
JS_ACCESS_AFTER_FLAGS=$(echo "$JS_ACCESS_AFTER" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('gateStatus')=='COMING_SOON')")
ok "jeongseok access gateStatus COMING_SOON after restore" "$JS_ACCESS_AFTER_FLAGS"

echo "== teardown fixtures =="
node seed-gate-fixtures.mjs teardown
echo "seed-gate: pass=$pass fail=$fail"
[ "$fail" = "0" ]
