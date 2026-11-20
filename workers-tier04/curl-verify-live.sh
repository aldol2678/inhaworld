#!/usr/bin/env bash
# Curl verification for the isolated Worker
# https://inha-world-tier04.aldol-lab.workers.dev
# Usage: ./curl-verify.sh ; prints one line per case: NAME HTTP BODY-snippet
# Fixtures must be set up first (curl-fixtures.mjs setup) and torn down after.
# The quiz/landlord lookups call `node curl-fixtures.mjs quiz-answer` /
# `landlord-survivor`, so TEST_OWNER_URL must be set in the environment.
BASE="https://inha-world-tier04.aldol-lab.workers.dev"
A="d1000000-0000-4000-8000-000000000001" # curl-alice (profile, wallet 500)
B="d2000000-0000-4000-8000-000000000002" # curl-bob (profile, wallet 500)
N="d4000000-0000-4000-8000-000000000004" # curl-noprofile (session only)
X="d3000000-0000-4000-8000-000000000003" # curl-banned (banned profile)
D="d5000000-0000-4000-8000-000000000005" # curl-dave (profile, friend-cycle target)
U="d9000000-0000-4000-8000-000000000009" # unknown session
pass=0; fail=0
t() { # t NAME WANT_HTTP METHOD PATH SESSION BODY
  local name="$1" want="$2" method="$3" path="$4" sess="$5" body="$6"
  local code out
  if [ -n "$sess" ]; then
    out=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json" -H "X-Session-Id: $sess" ${body:+--data "$body"} 2>&1)
  else
    out=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json" ${body:+--data "$body"} 2>&1)
  fi
  code=$(echo "$out" | tail -n 1)
  local resp=$(echo "$out" | head -n -1 | head -c 300)
  if [ "$code" = "$want" ]; then pass=$((pass+1)); echo "PASS $name -> $code $resp"; else fail=$((fail+1)); echo "FAIL $name -> got $code want $want $resp"; fi
}

# ---- loadout ----
t "loadout equip cap" 200 POST /api/world-loadout "$A" '{"action":"equip","slot":"HEAD","itemId":"head.induck_cap","idempotencyKey":"curl-equip-1"}'
t "loadout equip cap replay" 200 POST /api/world-loadout "$A" '{"action":"equip","slot":"HEAD","itemId":"head.induck_cap","idempotencyKey":"curl-equip-1"}'
t "loadout equip same key diff item" 409 POST /api/world-loadout "$A" '{"action":"equip","slot":"HEAD","itemId":"top.induck_hoodie","idempotencyKey":"curl-equip-1"}'
t "loadout equip not owned" 409 POST /api/world-loadout "$A" '{"action":"equip","slot":"SHOES","itemId":"shoes.campus_sneakers","idempotencyKey":"curl-equip-2"}'
t "loadout equip bad slot" 400 POST /api/world-loadout "$A" '{"action":"equip","slot":"ARMS","itemId":"head.induck_cap","idempotencyKey":"curl-equip-3"}'
t "loadout unequip" 200 POST /api/world-loadout "$A" '{"action":"unequip","slot":"HEAD","idempotencyKey":"curl-unequip-1"}'
t "loadout get" 200 GET /api/world-loadout "$A" ""
t "loadout no session" 401 POST /api/world-loadout "" '{"action":"equip","slot":"HEAD","itemId":"head.induck_cap","idempotencyKey":"curl-equip-9"}'
t "loadout unknown session" 401 POST /api/world-loadout "$U" '{"action":"equip","slot":"HEAD","itemId":"head.induck_cap","idempotencyKey":"curl-equip-9"}'
t "loadout bad action" 400 POST /api/world-loadout "$A" '{"action":"dance","slot":"HEAD","idempotencyKey":"curl-equip-9"}'

# ---- shop purchase ----
t "purchase v1 sneakers" 200 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.campus_sneakers","idempotencyKey":"curl-buy-1"}'
t "purchase v1 sneakers replay" 200 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.campus_sneakers","idempotencyKey":"curl-buy-1"}'
t "purchase v1 same key diff listing" 409 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.campus_mug","idempotencyKey":"curl-buy-1"}'
t "purchase v1 mug" 200 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.campus_mug","idempotencyKey":"curl-buy-2"}'
t "purchase v1 mug already owned" 409 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.campus_mug","idempotencyKey":"curl-buy-3"}'
t "purchase v1 unknown listing" 409 POST /api/world-shop-purchase "$A" '{"listingId":"offer.student_center.nope","idempotencyKey":"curl-buy-3"}'
t "purchase v2 cushion bob" 200 POST /api/world-shop-purchase "$B" '{"listingId":"offer.dorm_furniture.induck_cushion","idempotencyKey":"curl-buy-4","shopId":"shop.dorm_furniture"}'
t "purchase v2 cushion replay" 200 POST /api/world-shop-purchase "$B" '{"listingId":"offer.dorm_furniture.induck_cushion","idempotencyKey":"curl-buy-4","shopId":"shop.dorm_furniture"}'
t "purchase v2 wrong shop" 409 POST /api/world-shop-purchase "$B" '{"listingId":"offer.dorm_furniture.induck_cushion","idempotencyKey":"curl-buy-5","shopId":"shop.student_center"}'
t "purchase v2 desk lamp insufficient funds (alice 260 < 280, lv2 ok)" 409 POST /api/world-shop-purchase "$A" '{"listingId":"offer.dorm_furniture.dorm_desk_lamp","idempotencyKey":"curl-buy-6","shopId":"shop.dorm_furniture"}'
t "purchase v2 sofa locked" 409 POST /api/world-shop-purchase "$A" '{"listingId":"offer.dorm_furniture.dorm_single_sofa","idempotencyKey":"curl-buy-7","shopId":"shop.dorm_furniture"}'
t "purchase no session" 401 POST /api/world-shop-purchase "" '{"listingId":"offer.student_center.campus_mug","idempotencyKey":"curl-buy-9"}'
t "purchase get 405" 405 GET /api/world-shop-purchase "$A" ""

# ---- attendance ----
t "attendance claim alice" 200 POST /api/world-attendance-claim "$A" '{}'
t "attendance claim alice replay" 200 POST /api/world-attendance-claim "$A" '{}'
t "attendance get alice" 200 GET /api/world-attendance "$A" ""
t "attendance claim no session" 401 POST /api/world-attendance-claim "" '{}'
t "attendance get no session" 401 GET /api/world-attendance "" ""

# ---- guestbook (one create per 60 s cooldown; the first create IS the success case) ----
GB_CREATE_CODE=$(curl -s -o /tmp/gb-create.json -w "%{http_code}" -X POST "$BASE/api/world-guestbook" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{"action":"create","content":"curl hello","location":"main_gate"}')
GB_ID=$(python3 -c "import json;print(json.load(open('/tmp/gb-create.json')).get('id',''))")
if [ "$GB_CREATE_CODE" = "200" ] && [ -n "$GB_ID" ]; then pass=$((pass+1)); echo "PASS guestbook create alice -> $GB_CREATE_CODE entry $GB_ID"; else fail=$((fail+1)); echo "FAIL guestbook create alice -> $GB_CREATE_CODE $(head -c 200 /tmp/gb-create.json)"; fi
t "guestbook update alice" 200 POST /api/world-guestbook "$A" "{\"action\":\"update\",\"entryId\":\"$GB_ID\",\"content\":\"curl hello edited\"}"
t "guestbook update bob denied" 400 POST /api/world-guestbook "$B" "{\"action\":\"update\",\"entryId\":\"$GB_ID\",\"content\":\"hacked\"}"
t "guestbook delete bob denied" 400 POST /api/world-guestbook "$B" "{\"action\":\"delete\",\"entryId\":\"$GB_ID\"}"
t "guestbook delete alice" 200 POST /api/world-guestbook "$A" "{\"action\":\"delete\",\"entryId\":\"$GB_ID\"}"
t "guestbook create noprofile 409" 409 POST /api/world-guestbook "$N" '{"action":"create","content":"x","location":"main_gate"}'
t "guestbook create banned 409" 409 POST /api/world-guestbook "$X" '{"action":"create","content":"x","location":"main_gate"}'
t "guestbook create empty 400" 400 POST /api/world-guestbook "$A" '{"action":"create","content":"","location":"main_gate"}'
t "guestbook create bad location 400" 400 POST /api/world-guestbook "$A" '{"action":"create","content":"ok","location":"nowhere"}'
t "guestbook get alice" 200 GET "/api/world-guestbook?limit=10" "$A" ""
t "guestbook get noprofile 409" 409 GET "/api/world-guestbook?limit=10" "$N" ""
t "guestbook no session" 401 POST /api/world-guestbook "" '{"action":"create","content":"x","location":"main_gate"}'

# ---- jeongseok (seed gate COMING_SOON) ----
t "jeongseok access seed" 200 GET /api/world-jeongseok-access "$A" ""
t "jeongseok purchase gate closed 409" 409 POST /api/world-jeongseok-pass "$A" '{"passType":"jeongseok.visitor.day","idempotencyKey":"curl-js-1"}'
t "jeongseok purchase no session" 401 POST /api/world-jeongseok-pass "" '{"passType":"jeongseok.visitor.day","idempotencyKey":"curl-js-9"}'
t "jeongseok access no session" 401 GET /api/world-jeongseok-access "" ""

# ---- cooking (seed recipe COMING_SOON) ----
t "cooking seed unavailable 409" 409 POST /api/world-cooking "$A" '{"recipeId":"recipe.carp_grill","requestId":"e1000000-0000-4000-8000-000000000001"}'
t "cooking bad request id 400" 400 POST /api/world-cooking "$A" '{"recipeId":"recipe.carp_grill","requestId":"not-a-uuid"}'
t "cooking no session" 401 POST /api/world-cooking "" '{"recipeId":"recipe.carp_grill","requestId":"e1000000-0000-4000-8000-000000000001"}'

# ---- personal room ----
ROOM_A=$(curl -s -X POST "$BASE/api/world-personal-room" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{"action":"ensure"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('roomId',''))")
echo "personal room alice: $ROOM_A"
t "personal room ensure alice" 200 POST /api/world-personal-room "$A" '{"action":"ensure"}'
t "personal room get alice" 200 GET /api/world-personal-room "$A" ""
t "personal room set private" 200 POST /api/world-personal-room "$A" '{"action":"setVisibility","visibility":"private"}'
t "personal room invalid visibility 400" 400 POST /api/world-personal-room "$A" '{"action":"setVisibility","visibility":"public"}'
t "personal room no session" 401 POST /api/world-personal-room "" '{"action":"ensure"}'
ROOM_B=$(curl -s -X POST "$BASE/api/world-personal-room" -H "Content-Type: application/json" -H "X-Session-Id: $B" --data '{"action":"ensure"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('roomId',''))")
echo "personal room bob: $ROOM_B"

# ---- furniture ----
t "furniture save rev0" 200 POST /api/world-room-furniture "$A" "{\"roomId\":\"$ROOM_A\",\"revision\":0,\"objects\":[{\"id\":\"c1000000-0000-4000-8000-000000000001\",\"itemId\":\"furniture.induck_chair\",\"surface\":\"floor\",\"x\":0,\"z\":0,\"yaw\":0}]}"
t "furniture stale rev0 409" 409 POST /api/world-room-furniture "$A" "{\"roomId\":\"$ROOM_A\",\"revision\":0,\"objects\":[{\"id\":\"c1000000-0000-4000-8000-000000000001\",\"itemId\":\"furniture.induck_chair\",\"surface\":\"floor\",\"x\":1,\"z\":0,\"yaw\":0}]}"
t "furniture identical retry rev0" 200 POST /api/world-room-furniture "$A" "{\"roomId\":\"$ROOM_A\",\"revision\":0,\"objects\":[{\"id\":\"c1000000-0000-4000-8000-000000000001\",\"itemId\":\"furniture.induck_chair\",\"surface\":\"floor\",\"x\":0,\"z\":0,\"yaw\":0}]}"
t "furniture get alice" 200 GET "/api/world-room-furniture?room_id=$ROOM_A" "$A" ""
t "furniture get bob denied 403" 403 GET "/api/world-room-furniture?room_id=$ROOM_A" "$B" ""
t "furniture save bob denied 403" 403 POST /api/world-room-furniture "$B" "{\"roomId\":\"$ROOM_A\",\"revision\":1,\"objects\":[]}"
t "furniture bad surface 400" 400 POST /api/world-room-furniture "$A" "{\"roomId\":\"$ROOM_A\",\"revision\":1,\"objects\":[{\"id\":\"c1000000-0000-4000-8000-000000000001\",\"itemId\":\"furniture.induck_chair\",\"surface\":\"ceiling\",\"x\":0,\"z\":0,\"yaw\":0}]}"
t "furniture no session" 401 POST /api/world-room-furniture "" "{\"roomId\":\"$ROOM_A\",\"revision\":1,\"objects\":[]}"

# ---- knock (alice -> bob: bob not home -> OPEN) ----
KNOCK_RESP=$(curl -s -X POST "$BASE/api/world-room-knock" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data "{\"action\":\"knock\",\"ownerUserId\":\"$B\"}")
KNOCK_ID=$(echo "$KNOCK_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('knockId',''))")
echo "knock: $KNOCK_ID"
t "knock alice->bob" 200 POST /api/world-room-knock "$A" "{\"action\":\"knock\",\"ownerUserId\":\"$B\"}"
t "knock alice->bob repeat" 200 POST /api/world-room-knock "$A" "{\"action\":\"knock\",\"ownerUserId\":\"$B\"}"
t "knock self 400" 400 POST /api/world-room-knock "$A" "{\"action\":\"knock\",\"ownerUserId\":\"$A\"}"
t "knock noprofile 409" 409 POST /api/world-room-knock "$N" "{\"action\":\"knock\",\"ownerUserId\":\"$B\"}"
t "knock no session" 401 POST /api/world-room-knock "" "{\"action\":\"knock\",\"ownerUserId\":\"$B\"}"
t "knock list bob" 200 POST /api/world-room-knock "$B" '{"action":"list"}'
t "knock get by visitor" 200 POST /api/world-room-knock "$A" "{\"action\":\"get\",\"knockId\":\"$KNOCK_ID\"}"
t "knock respond OPEN unchanged (owner)" 200 POST /api/world-room-knock "$B" "{\"action\":\"respond\",\"knockId\":\"$KNOCK_ID\",\"accept\":true}"
t "knock get unknown 404" 404 POST /api/world-room-knock "$A" '{"action":"get","knockId":"e9000000-0000-4000-8000-000000000001"}'
t "knock bad action 400" 400 POST /api/world-room-knock "$A" '{"action":"wave"}'

# ---- daily quiz (A-3) ----
t "quiz get alice" 200 GET /api/world-daily-quiz "$A" ""
t "quiz get noprofile (session-only)" 200 GET /api/world-daily-quiz "$N" ""
t "quiz get no session" 401 GET /api/world-daily-quiz "" ""
QUIZ_START=$(curl -s -X POST "$BASE/api/world-daily-quiz-start" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{}')
QUIZ_RUN=$(echo "$QUIZ_START" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('runId',''))")
QUIZ_Q=$(echo "$QUIZ_START" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('question') or {}).get('questionId',''))")
echo "quiz start: run=$QUIZ_RUN q=$QUIZ_Q"
t "quiz start alice" 200 POST /api/world-daily-quiz-start "$A" '{}'
QUIZ_START2=$(curl -s -X POST "$BASE/api/world-daily-quiz-start" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{}')
QUIZ_RUN2=$(echo "$QUIZ_START2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('runId',''))")
if [ "$QUIZ_RUN" = "$QUIZ_RUN2" ] && [ -n "$QUIZ_RUN" ]; then pass=$((pass+1)); echo "PASS quiz start same run -> $QUIZ_RUN"; else fail=$((fail+1)); echo "FAIL quiz start same run -> $QUIZ_RUN vs $QUIZ_RUN2"; fi
QUIZ_CORRECT=$(node curl-fixtures.mjs quiz-answer "$QUIZ_Q")
QUIZ_WRONG=$(( (QUIZ_CORRECT + 1) % 4 ))
t "quiz answer wrong Q1" 200 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q\",\"answerIndex\":$QUIZ_WRONG}"
QUIZ_GET2=$(curl -s "$BASE/api/world-daily-quiz" -H "X-Session-Id: $A")
QUIZ_Q2=$(echo "$QUIZ_GET2" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('question') or {}).get('questionId',''))")
QUIZ_CORRECT2=$(node curl-fixtures.mjs quiz-answer "$QUIZ_Q2")
t "quiz answer correct Q2" 200 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q2\",\"answerIndex\":$QUIZ_CORRECT2}"
QUIZ_GET3=$(curl -s "$BASE/api/world-daily-quiz" -H "X-Session-Id: $A")
QUIZ_Q3=$(echo "$QUIZ_GET3" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('question') or {}).get('questionId',''))")
QUIZ_CORRECT3=$(node curl-fixtures.mjs quiz-answer "$QUIZ_Q3")
t "quiz answer correct Q3 (PASSED)" 200 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q3\",\"answerIndex\":$QUIZ_CORRECT3}"
QUIZ_AFTER=$(curl -s "$BASE/api/world-daily-quiz" -H "X-Session-Id: $A")
QUIZ_STATUS=$(echo "$QUIZ_AFTER" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))")
if [ "$QUIZ_STATUS" = "PASSED" ]; then pass=$((pass+1)); echo "PASS quiz status PASSED after 2/3 correct"; else fail=$((fail+1)); echo "FAIL quiz status PASSED -> got $QUIZ_STATUS"; fi
t "quiz answer after pass 409" 409 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q3\",\"answerIndex\":$QUIZ_CORRECT3}"
t "quiz answer bad index 400" 400 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q3\",\"answerIndex\":5}"
t "quiz answer unknown run 404" 404 POST /api/world-daily-quiz-answer "$A" "{\"runId\":\"e9000000-0000-4000-8000-000000000001\",\"questionId\":\"$QUIZ_Q3\",\"answerIndex\":0}"
t "quiz answer no session 401" 401 POST /api/world-daily-quiz-answer "" "{\"runId\":\"$QUIZ_RUN\",\"questionId\":\"$QUIZ_Q3\",\"answerIndex\":0}"
t "quiz answer get 405" 405 GET /api/world-daily-quiz-answer "$A" ""

# ---- life skills (A-3; alice seeded life.fishing 300 XP = level 3, SP 2) ----
t "life skills alice" 200 GET /api/world-life-skills "$A" ""
t "life tree fishing" 200 GET "/api/world-life-skill-tree?skill_id=life.fishing" "$A" ""
t "life tree noprofile (session-only)" 200 GET "/api/world-life-skill-tree?skill_id=life.fishing" "$N" ""
t "life tree unknown skill 404" 404 GET "/api/world-life-skill-tree?skill_id=life.nope" "$A" ""
t "life unlock steady_hands" 200 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.steady_hands","requestId":"e1000000-0000-4000-8000-000000000101"}'
t "life unlock steady_hands replay" 200 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.steady_hands","requestId":"e1000000-0000-4000-8000-000000000101"}'
t "life unlock same key diff node 409" 409 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.fish_sense","requestId":"e1000000-0000-4000-8000-000000000101"}'
t "life unlock fish_sense" 200 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.fish_sense","requestId":"e1000000-0000-4000-8000-000000000102"}'
t "life unlock SP exhausted 409" 409 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.steady_hands","requestId":"e1000000-0000-4000-8000-000000000103"}'
t "life unlock coming soon node 404" 404 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.fishing.baitcraft","requestId":"e1000000-0000-4000-8000-000000000104"}'
t "life unlock bad node 404" 404 POST /api/world-life-node-unlock "$A" '{"nodeId":"life.node.nope","requestId":"e1000000-0000-4000-8000-000000000105"}'
t "life reset" 200 POST /api/world-life-tree-reset "$A" '{"skillId":"life.fishing","requestId":"e1000000-0000-4000-8000-000000000106"}'
t "life reset replay" 200 POST /api/world-life-tree-reset "$A" '{"skillId":"life.fishing","requestId":"e1000000-0000-4000-8000-000000000106"}'
t "life reset cooldown 409" 409 POST /api/world-life-tree-reset "$A" '{"skillId":"life.fishing","requestId":"e1000000-0000-4000-8000-000000000107"}'
t "life reset bad skill 404" 404 POST /api/world-life-tree-reset "$A" '{"skillId":"life.nope","requestId":"e1000000-0000-4000-8000-000000000108"}'
t "life unlock no session 401" 401 POST /api/world-life-node-unlock "" '{"nodeId":"life.node.fishing.steady_hands","requestId":"e1000000-0000-4000-8000-000000000109"}'
t "life unlock get 405" 405 GET /api/world-life-node-unlock "$A" ""

# ---- social (A-3; alice-bob already friends via fixtures; dave is fresh) ----
t "social mine alice" 200 GET /api/world-social "$A" ""
t "social mine noprofile 409" 409 GET /api/world-social "$N" ""
t "social mine banned 409" 409 GET /api/world-social "$X" ""
t "social profile bob" 200 GET "/api/world-public-profile?target=$B" "$A" ""
t "social profile self 400" 400 GET "/api/world-public-profile?target=$A" "$A" ""
t "social profile unknown 400" 400 GET "/api/world-public-profile?target=$U" "$A" ""
t "social relationship bob" 200 GET "/api/world-relationship?target=$B" "$A" ""
t "social send alice->dave" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social send alice->dave again" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social mine dave incoming" 200 GET /api/world-social "$D" ""
t "social dave accept" 200 POST /api/world-friend-request "$D" "{\"action\":\"respond\",\"target\":\"$A\",\"accept\":true}"
t "social send to friend" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social remove dave" 200 POST /api/world-friend-request "$A" "{\"action\":\"remove\",\"target\":\"$D\"}"
t "social send alice->dave 2nd" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social cancel" 200 POST /api/world-friend-request "$A" "{\"action\":\"cancel\",\"target\":\"$D\"}"
t "social send alice->dave 3rd" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social dave decline" 200 POST /api/world-friend-request "$D" "{\"action\":\"respond\",\"target\":\"$A\",\"accept\":false}"
t "social report dave spam" 200 POST /api/world-report-user "$A" "{\"target\":\"$D\",\"category\":\"spam\"}"
t "social report dave spam duplicate" 200 POST /api/world-report-user "$A" "{\"target\":\"$D\",\"category\":\"spam\"}"
t "social report bad category 400" 400 POST /api/world-report-user "$A" "{\"target\":\"$D\",\"category\":\"bogus\"}"
t "social report self 400" 400 POST /api/world-report-user "$A" "{\"target\":\"$A\",\"category\":\"spam\"}"
t "social send alice->dave 4th" 200 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social dave accept 2nd" 200 POST /api/world-friend-request "$D" "{\"action\":\"respond\",\"target\":\"$A\",\"accept\":true}"
t "social block dave" 200 POST /api/world-block-user "$A" "{\"action\":\"block\",\"target\":\"$D\"}"
t "social profile blocked_by_me" 200 GET "/api/world-public-profile?target=$D" "$A" ""
t "social send while blocked 403" 403 POST /api/world-friend-request "$A" "{\"action\":\"send\",\"target\":\"$D\"}"
t "social unblock dave" 200 POST /api/world-block-user "$A" "{\"action\":\"unblock\",\"target\":\"$D\"}"
t "social block self 400" 400 POST /api/world-block-user "$A" "{\"action\":\"block\",\"target\":\"$A\"}"
t "social no session 401" 401 GET /api/world-social "" ""

# ---- accompany (A-3; alice-bob friends; expired fixture session present) ----
t "accompany get alice empty" 200 GET /api/world-accompany "$A" ""
t "accompany propose non-friend 403" 403 POST /api/world-accompany "$A" "{\"action\":\"propose\",\"target\":\"$D\",\"poiId\":\"poi.main-gate\",\"placeZoneId\":\"AREA_MAIN_GATE\"}"
ACC_RESP=$(curl -s -X POST "$BASE/api/world-accompany" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data "{\"action\":\"propose\",\"target\":\"$B\",\"poiId\":\"poi.main-gate\",\"placeZoneId\":\"AREA_MAIN_GATE\"}")
ACC_ID=$(echo "$ACC_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
echo "accompany session: $ACC_ID"
t "accompany propose alice->bob" 200 POST /api/world-accompany "$A" "{\"action\":\"propose\",\"target\":\"$B\",\"poiId\":\"poi.main-gate\",\"placeZoneId\":\"AREA_MAIN_GATE\"}"
t "accompany get bob offered" 200 GET /api/world-accompany "$B" ""
t "accompany respond non-invitee 400" 400 POST /api/world-accompany "$D" "{\"action\":\"respond\",\"sessionId\":\"$ACC_ID\",\"accept\":true}"
t "accompany respond bob accept" 200 POST /api/world-accompany "$B" "{\"action\":\"respond\",\"sessionId\":\"$ACC_ID\",\"accept\":true}"
t "accompany respond replay" 200 POST /api/world-accompany "$B" "{\"action\":\"respond\",\"sessionId\":\"$ACC_ID\",\"accept\":true}"
t "accompany end bob" 200 POST /api/world-accompany "$B" "{\"action\":\"end\",\"sessionId\":\"$ACC_ID\"}"
t "accompany end replay" 200 POST /api/world-accompany "$A" "{\"action\":\"end\",\"sessionId\":\"$ACC_ID\"}"
t "accompany get alice empty after end" 200 GET /api/world-accompany "$A" ""
t "accompany end non-participant 400" 400 POST /api/world-accompany "$D" "{\"action\":\"end\",\"sessionId\":\"$ACC_ID\"}"
t "accompany bad poi 400" 400 POST /api/world-accompany "$A" "{\"action\":\"propose\",\"target\":\"$B\",\"poiId\":\"poi.nope\",\"placeZoneId\":\"AREA_MAIN_GATE\"}"
t "accompany bad zone 400" 400 POST /api/world-accompany "$A" "{\"action\":\"propose\",\"target\":\"$B\",\"poiId\":\"poi.main-gate\",\"placeZoneId\":\"ZONE\"}"
t "accompany propose self 400" 400 POST /api/world-accompany "$A" "{\"action\":\"propose\",\"target\":\"$A\",\"poiId\":\"poi.main-gate\",\"placeZoneId\":\"AREA_MAIN_GATE\"}"
t "accompany respond expired 400" 400 POST /api/world-accompany "$B" "{\"action\":\"respond\",\"sessionId\":\"f1000000-0000-4000-8000-000000000001\",\"accept\":true}"
t "accompany no session 401" 401 GET /api/world-accompany "" ""

# ---- biryong progress + NPC relationships (A-3) ----
t "biryong progress fresh" 200 GET /api/world-biryong-progress "$A" ""
t "biryong merge FIND_CENTER" 200 POST /api/world-biryong-progress "$A" '{"progress":{"step":"FIND_CENTER","lore":["lore.a"],"shouts":2},"migratedFromLocal":false}'
t "biryong merge older step" 200 POST /api/world-biryong-progress "$A" '{"progress":{"step":"INTRO","lore":["lore.b"],"shouts":1},"migratedFromLocal":false}'
t "biryong merge bad step 400" 400 POST /api/world-biryong-progress "$A" '{"progress":{"step":"BOGUS"},"migratedFromLocal":false}'
t "biryong merge null 400" 400 POST /api/world-biryong-progress "$A" '{"progress":null,"migratedFromLocal":false}'
t "biryong merge noprofile" 200 POST /api/world-biryong-progress "$N" '{"progress":{"step":"INTRO"},"migratedFromLocal":false}'
t "biryong progress get alice" 200 GET /api/world-biryong-progress "$A" ""
t "biryong npc list" 200 GET /api/world-biryong-npc-relationships "$A" ""
t "biryong npc 001" 200 GET "/api/world-biryong-npc-relationship?npc_id=BR_NPC_001" "$A" ""
t "biryong npc unknown 404" 404 GET "/api/world-biryong-npc-relationship?npc_id=BR_NPC_999" "$A" ""
t "biryong advance 1->2" 200 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_001","targetStage":2,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-1"}'
t "biryong advance replay" 200 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_001","targetStage":2,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-1"}'
t "biryong advance same key diff target 409" 409 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_001","targetStage":3,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-1"}'
t "biryong advance 2->3" 200 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_001","targetStage":3,"sourceType":"EVENT","sourceRef":"event/test","resultRef":"result/test","idempotencyKey":"curl-biryong-2"}'
t "biryong advance to current (null resultRef)" 200 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_001","targetStage":3,"sourceType":"SYSTEM","sourceRef":"system/test","resultRef":null,"idempotencyKey":"curl-biryong-3"}'
t "biryong advance skip 409" 409 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_002","targetStage":3,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-4"}'
t "biryong advance bad source 400" 400 POST /api/world-biryong-npc-advance "$A" '{"npcId":"BR_NPC_002","targetStage":2,"sourceType":"MAGIC","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-5"}'
t "biryong advance noprofile" 200 POST /api/world-biryong-npc-advance "$N" '{"npcId":"BR_NPC_002","targetStage":2,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-6"}'
t "biryong advance no session 401" 401 POST /api/world-biryong-npc-advance "" '{"npcId":"BR_NPC_001","targetStage":2,"sourceType":"QUEST","sourceRef":"quest/test","resultRef":"result/test","idempotencyKey":"curl-biryong-9"}'

# ---- campus NPC relationships (A-3) ----
t "campus npc list" 200 GET /api/world-campus-npc-relationships "$A" ""
t "campus npc 001" 200 GET "/api/world-campus-npc-relationship?npc_id=INKYUNG-NPC-001" "$A" ""
t "campus npc unknown 404" 404 GET "/api/world-campus-npc-relationship?npc_id=INKYUNG-NPC-999" "$A" ""
t "campus apply FIRST_MEETING (null signal)" 200 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"FIRST_MEETING","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-1"}'
t "campus apply replay" 200 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"FIRST_MEETING","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-1"}'
t "campus apply second FIRST_MEETING" 200 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"FIRST_MEETING","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-2"}'
t "campus apply MEANINGFUL_DIALOGUE" 200 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"MEANINGFUL_DIALOGUE","signal":"GREETING_WARM","occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-3"}'
t "campus apply NEGATIVE_CHOICE (null signal)" 200 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"NEGATIVE_CHOICE","signal":null,"occurrence":1,"requestedDelta":-3,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-4"}'
t "campus apply bad sign 400" 400 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"NEGATIVE_CHOICE","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-5"}'
t "campus apply version mismatch 400" 400 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":2,"eventType":"REUNION","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-6"}'
t "campus apply unknown npc 404" 404 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-999","definitionVersion":1,"eventType":"REUNION","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-7"}'
t "campus apply delta 11 400" 400 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"REUNION","signal":null,"occurrence":1,"requestedDelta":11,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-8"}'
t "campus apply bad event 400" 400 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"HUG","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-9"}'
t "campus apply bad signal 400" 400 POST /api/world-campus-npc-apply "$A" '{"npcId":"INKYUNG-NPC-001","definitionVersion":1,"eventType":"REUNION","signal":"lower","occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-10"}'
t "campus apply noprofile" 200 POST /api/world-campus-npc-apply "$N" '{"npcId":"INKYUNG-NPC-002","definitionVersion":1,"eventType":"FIRST_MEETING","signal":null,"occurrence":1,"requestedDelta":5,"sourceType":"DIALOGUE","sourceRef":"curl/test","idempotencyKey":"curl-campus-11"}'

# ---- MCM 2026 (A-3; window flipped ACTIVE by fixtures; 45 s landlord deadline) ----
t "mcm get alice" 200 GET /api/world-mcm-event "$A" ""
t "mcm get noprofile (session-only)" 200 GET /api/world-mcm-event "$N" ""
t "mcm claim main bob not eligible 409" 409 POST /api/world-mcm-claim "$B" '{"claim":"main"}'
t "mcm claim landlord bob not eligible 409" 409 POST /api/world-mcm-claim "$B" '{"claim":"landlord_first_clear"}'
# The main event advances only via the server-only advance RPC (no HTTP
# endpoint by design): start + investigate x3 -> VENUE_UNLOCKED. Drive it
# through the fixtures helper, then the landlord clear completes the event.
MCM_STAGE2=$(node curl-fixtures.mjs mcm-advance "$A")
if [ "$MCM_STAGE2" = "VENUE_UNLOCKED" ]; then pass=$((pass+1)); echo "PASS mcm advance start+investigates -> VENUE_UNLOCKED"; else fail=$((fail+1)); echo "FAIL mcm advance start+investigates -> got $MCM_STAGE2"; fi
MCM_RUN_RESP=$(curl -s -X POST "$BASE/api/world-mcm-landlord-run" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{}')
MCM_RUN=$(echo "$MCM_RUN_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('runId',''))")
echo "mcm landlord run: $MCM_RUN"
t "mcm landlord start" 200 POST /api/world-mcm-landlord-run "$A" '{}'
MCM_RUN2=$(curl -s -X POST "$BASE/api/world-mcm-landlord-run" -H "Content-Type: application/json" -H "X-Session-Id: $A" --data '{}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('runId',''))")
if [ "$MCM_RUN" = "$MCM_RUN2" ] && [ -n "$MCM_RUN" ]; then pass=$((pass+1)); echo "PASS mcm landlord start resumes same run -> $MCM_RUN"; else fail=$((fail+1)); echo "FAIL mcm landlord start resumes same run -> $MCM_RUN vs $MCM_RUN2"; fi
MCM_SURVIVOR=$(node curl-fixtures.mjs landlord-survivor "$MCM_RUN")
MCM_WRONG="ZUE-MG-001"; if [ "$MCM_SURVIVOR" = "ZUE-MG-001" ]; then MCM_WRONG="ZUE-MG-002"; fi
t "mcm landlord bad actor 400" 400 POST /api/world-mcm-landlord-choice "$A" "{\"runId\":\"$MCM_RUN\",\"actorId\":\"ZUE-MG-999\"}"
t "mcm landlord wrong choice" 200 POST /api/world-mcm-landlord-choice "$A" "{\"runId\":\"$MCM_RUN\",\"actorId\":\"$MCM_WRONG\"}"
t "mcm landlord correct choice" 200 POST /api/world-mcm-landlord-choice "$A" "{\"runId\":\"$MCM_RUN\",\"actorId\":\"$MCM_SURVIVOR\"}"
t "mcm landlord resubmit" 200 POST /api/world-mcm-landlord-choice "$A" "{\"runId\":\"$MCM_RUN\",\"actorId\":\"$MCM_SURVIVOR\"}"
MCM_AFTER=$(curl -s "$BASE/api/world-mcm-event" -H "X-Session-Id: $A")
MCM_STAGE=$(echo "$MCM_AFTER" | python3 -c "import sys,json;print(json.load(sys.stdin).get('progress',{}).get('stage',''))")
if [ "$MCM_STAGE" = "COMPLETED" ]; then pass=$((pass+1)); echo "PASS mcm stage COMPLETED after landlord clear"; else fail=$((fail+1)); echo "FAIL mcm stage COMPLETED -> got $MCM_STAGE"; fi
t "mcm claim landlord" 200 POST /api/world-mcm-claim "$A" '{"claim":"landlord_first_clear"}'
t "mcm claim landlord replay" 200 POST /api/world-mcm-claim "$A" '{"claim":"landlord_first_clear"}'
t "mcm claim main" 200 POST /api/world-mcm-claim "$A" '{"claim":"main"}'
t "mcm claim main replay" 200 POST /api/world-mcm-claim "$A" '{"claim":"main"}'
t "mcm claim bad type 400" 400 POST /api/world-mcm-claim "$A" '{"claim":"bogus"}'
t "mcm get no session 401" 401 GET /api/world-mcm-event "" ""
t "mcm claim get 405" 405 GET /api/world-mcm-claim "$A" ""

# ---- method / origin guards ----
t "loadout get is allowed (read)" 200 GET /api/world-loadout "$A" ""
t "attendance-claim get 405" 405 GET /api/world-attendance-claim "$A" ""
t "cooking get 405" 405 GET /api/world-cooking "$A" ""
# Wrong Origin must be rejected (the t() helper sends no Origin, so test it directly).
ORIGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-loadout" -H "Content-Type: application/json" -H "X-Session-Id: $A" -H "Origin: https://evil.example" --data '{"action":"equip","slot":"HEAD","itemId":"head.induck_cap","idempotencyKey":"curl-origin-1"}')
if [ "$ORIGIN_CODE" = "403" ]; then pass=$((pass+1)); echo "PASS wrong origin 403 -> $ORIGIN_CODE"; else fail=$((fail+1)); echo "FAIL wrong origin 403 -> got $ORIGIN_CODE"; fi

# ---- BCD: mail manual verification (D-1 fallback (c)) ----
# Runs BEFORE the profile section so H has no profile yet (claim without a
# profile must still create the badge but grant no achievement).
E="e6000000-0000-4000-8000-000000000006" # BCD profile-new (session only)
F="e7000000-0000-4000-8000-000000000007" # BCD mail-new (session only)
G="e8000000-0000-4000-8000-000000000008" # BCD online + nickname false-positive
H="e9000000-0000-4000-8000-000000000009" # BCD duplicate/banned probes + claim-without-profile
MAIL_F_CODE=$(curl -s -o /tmp/mail-f.json -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-request" -H "Content-Type: application/json" -H "X-Session-Id: $F" --data '{"email":"f@inha.edu"}')
REQ_F=$(python3 -c "import json;print(json.load(open('/tmp/mail-f.json')).get('requestId',''))")
if [ "$MAIL_F_CODE" = "201" ] && [ -n "$REQ_F" ]; then pass=$((pass+1)); echo "PASS mail request f new -> $MAIL_F_CODE $REQ_F"; else fail=$((fail+1)); echo "FAIL mail request f new -> $MAIL_F_CODE $(head -c 200 /tmp/mail-f.json)"; fi
MAIL_F2_CODE=$(curl -s -o /tmp/mail-f2.json -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-request" -H "Content-Type: application/json" -H "X-Session-Id: $F" --data '{"email":"f@inha.edu"}')
REQ_F2=$(python3 -c "import json;print(json.load(open('/tmp/mail-f2.json')).get('requestId',''))")
if [ "$MAIL_F2_CODE" = "200" ] && [ "$REQ_F2" = "$REQ_F" ]; then pass=$((pass+1)); echo "PASS mail request f duplicate same id -> $MAIL_F2_CODE"; else fail=$((fail+1)); echo "FAIL mail request f duplicate -> $MAIL_F2_CODE $REQ_F2 vs $REQ_F"; fi
t "mail request bad domain 400" 400 POST /api/world-mail-verify-request "$F" '{"email":"f@gmail.com"}'
t "mail request not an email 400" 400 POST /api/world-mail-verify-request "$F" '{"email":"not-an-email"}'
t "mail request second address 201" 201 POST /api/world-mail-verify-request "$F" '{"email":"f@inha.ac.kr"}'
t "mail request no session 401" 401 POST /api/world-mail-verify-request "" '{"email":"f@inha.edu"}'
MAIL_H_CODE=$(curl -s -o /tmp/mail-h.json -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-request" -H "Content-Type: application/json" -H "X-Session-Id: $H" --data '{"email":"h@inha.edu"}')
REQ_H=$(python3 -c "import json;print(json.load(open('/tmp/mail-h.json')).get('requestId',''))")
if [ "$MAIL_H_CODE" = "201" ] && [ -n "$REQ_H" ]; then pass=$((pass+1)); echo "PASS mail request h new -> $MAIL_H_CODE $REQ_H"; else fail=$((fail+1)); echo "FAIL mail request h new -> $MAIL_H_CODE $(head -c 200 /tmp/mail-h.json)"; fi
MAIL_D_CODE=$(curl -s -o /tmp/mail-d.json -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-request" -H "Content-Type: application/json" -H "X-Session-Id: $D" --data '{"email":"dave@inha.edu"}')
REQ_D=$(python3 -c "import json;print(json.load(open('/tmp/mail-d.json')).get('requestId',''))")
if [ "$MAIL_D_CODE" = "201" ] && [ -n "$REQ_D" ]; then pass=$((pass+1)); echo "PASS mail request dave new -> $MAIL_D_CODE $REQ_D"; else fail=$((fail+1)); echo "FAIL mail request dave new -> $MAIL_D_CODE $(head -c 200 /tmp/mail-d.json)"; fi
if [ -z "$MAIL_ADMIN_KEY" ]; then
  echo "SKIP mail claim tests (MAIL_ADMIN_KEY unset)"
else
  CLAIM_WRONG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" -H "X-Admin-Key: wrong-key-123" --data "{\"requestId\":\"$REQ_H\"}")
  if [ "$CLAIM_WRONG_CODE" = "403" ]; then pass=$((pass+1)); echo "PASS mail claim wrong admin key 403 -> $CLAIM_WRONG_CODE"; else fail=$((fail+1)); echo "FAIL mail claim wrong admin key 403 -> got $CLAIM_WRONG_CODE"; fi
  CLAIM_NOKEY_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" --data "{\"requestId\":\"$REQ_H\"}")
  if [ "$CLAIM_NOKEY_CODE" = "403" ]; then pass=$((pass+1)); echo "PASS mail claim no admin key 403 -> $CLAIM_NOKEY_CODE"; else fail=$((fail+1)); echo "FAIL mail claim no admin key 403 -> got $CLAIM_NOKEY_CODE"; fi
  CLAIM_UNKNOWN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" -H "X-Admin-Key: $MAIL_ADMIN_KEY" --data '{"requestId":"e9000000-0000-4000-8000-000000000099"}')
  if [ "$CLAIM_UNKNOWN_CODE" = "404" ]; then pass=$((pass+1)); echo "PASS mail claim unknown request 404 -> $CLAIM_UNKNOWN_CODE"; else fail=$((fail+1)); echo "FAIL mail claim unknown request 404 -> got $CLAIM_UNKNOWN_CODE"; fi
  CLAIM_H=$(curl -s -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" -H "X-Admin-Key: $MAIL_ADMIN_KEY" --data "{\"requestId\":\"$REQ_H\"}")
  CLAIM_H_FLAGS=$(echo "$CLAIM_H" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('verified'),d.get('achievementGranted'))")
  if [ "$CLAIM_H_FLAGS" = "True False" ]; then pass=$((pass+1)); echo "PASS mail claim h no-profile: badge yes, achievement no -> $CLAIM_H_FLAGS"; else fail=$((fail+1)); echo "FAIL mail claim h no-profile -> $CLAIM_H"; fi
  CLAIM_H2_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" -H "X-Admin-Key: $MAIL_ADMIN_KEY" --data "{\"requestId\":\"$REQ_H\"}")
  if [ "$CLAIM_H2_CODE" = "404" ]; then pass=$((pass+1)); echo "PASS mail claim h twice 404 -> $CLAIM_H2_CODE"; else fail=$((fail+1)); echo "FAIL mail claim h twice 404 -> got $CLAIM_H2_CODE"; fi
  CLAIM_D=$(curl -s -X POST "$BASE/api/world-mail-verify-claim" -H "Content-Type: application/json" -H "X-Admin-Key: $MAIL_ADMIN_KEY" --data "{\"requestId\":\"$REQ_D\"}")
  CLAIM_D_FLAGS=$(echo "$CLAIM_D" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('verified'),d.get('achievementGranted'),d.get('email'))")
  if [ "$CLAIM_D_FLAGS" = "True True dave@inha.edu" ]; then pass=$((pass+1)); echo "PASS mail claim dave with-profile: badge + achievement -> $CLAIM_D_FLAGS"; else fail=$((fail+1)); echo "FAIL mail claim dave with-profile -> $CLAIM_D"; fi
  t "mail rate limit g1 201" 201 POST /api/world-mail-verify-request "$G" '{"email":"g1@inha.edu"}'
  t "mail rate limit g2 201" 201 POST /api/world-mail-verify-request "$G" '{"email":"g2@inha.edu"}'
  t "mail rate limit g3 201" 201 POST /api/world-mail-verify-request "$G" '{"email":"g3@inha.edu"}'
  t "mail rate limit g4 429" 429 POST /api/world-mail-verify-request "$G" '{"email":"g4@inha.edu"}'
fi

# ---- BCD: profile creation (D-2/D-3/D-4) ----
t "profile create e new 201" 201 POST /api/world-profile "$E" '{"nickname":"curlnew","departmentId":10,"avatarKey":"scholar"}'
t "profile create e again 200 existing" 200 POST /api/world-profile "$E" '{"nickname":"othername","departmentId":1,"avatarKey":"star"}'
t "profile get e 200" 200 GET /api/world-profile "$E" ""
t "profile get noprofile 409" 409 GET /api/world-profile "$N" ""
t "profile get banned 409" 409 GET /api/world-profile "$X" ""
t "profile get no session 401" 401 GET /api/world-profile "" ""
t "profile get unknown 401" 401 GET /api/world-profile "$U" ""
t "profile create banned word 400" 400 POST /api/world-profile "$F" '{"nickname":"씨발왕","departmentId":10,"avatarKey":"scholar"}'
t "profile create too short 400" 400 POST /api/world-profile "$F" '{"nickname":"a","departmentId":10,"avatarKey":"scholar"}'
t "profile create bad char 400" 400 POST /api/world-profile "$F" '{"nickname":"bad!nick","departmentId":10,"avatarKey":"scholar"}'
# Note: a space IS allowed in nicknames — the RPC mirrors the origin CHECK
# ^[0-9A-Za-z가-힣_ ]+$ (run 1 observed 'bad nick' created with 201).
t "profile create too long 400" 400 POST /api/world-profile "$F" '{"nickname":"abcdefghijklm","departmentId":10,"avatarKey":"scholar"}'
t "profile create unknown dept 400" 400 POST /api/world-profile "$F" '{"nickname":"goodname","departmentId":9999,"avatarKey":"scholar"}'
t "profile create bad avatar 400" 400 POST /api/world-profile "$F" '{"nickname":"goodname","departmentId":10,"avatarKey":"dragon"}'
t "profile create f goodname 201" 201 POST /api/world-profile "$F" '{"nickname":"goodname","departmentId":10,"avatarKey":"scholar"}'
t "profile create false positive soyeon 201" 201 POST /api/world-profile "$G" '{"nickname":"소년연금술사","departmentId":10,"avatarKey":"classic"}'
t "profile create duplicate case-insensitive 409" 409 POST /api/world-profile "$H" '{"nickname":"CURLALICE","departmentId":1,"avatarKey":"classic"}'
t "profile create repeat-collapse banned 400" 400 POST /api/world-profile "$H" '{"nickname":"씨발발","departmentId":1,"avatarKey":"classic"}'
t "profile create noprofile 201" 201 POST /api/world-profile "$N" '{"nickname":"noprofile1","departmentId":1,"avatarKey":"classic"}'
t "profile create banned concealed 409" 409 POST /api/world-profile "$X" '{"nickname":"newname","departmentId":1,"avatarKey":"classic"}'
t "profile create no session 401" 401 POST /api/world-profile "" '{"nickname":"nosess","departmentId":1,"avatarKey":"classic"}'
t "profile create unknown 401" 401 POST /api/world-profile "$U" '{"nickname":"nosess","departmentId":1,"avatarKey":"classic"}'
PROFILE_TITLE=$(curl -s -X POST "$BASE/api/world-profile" -H "Content-Type: application/json" -H "X-Session-Id: $H" --data '{"nickname":"titledone","departmentId":10,"avatarKey":"classic","title":"hacker"}')
PROFILE_TITLE_FLAGS=$(echo "$PROFILE_TITLE" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('created'),d.get('title'),d.get('nickname'))")
if [ "$PROFILE_TITLE_FLAGS" = "True None titledone" ]; then pass=$((pass+1)); echo "PASS profile create title forced null -> $PROFILE_TITLE_FLAGS"; else fail=$((fail+1)); echo "FAIL profile create title forced null -> $PROFILE_TITLE"; fi

# ---- BCD: online heartbeat + count (C-group (b)) ----
t "online touch g 200" 200 POST /api/world-online-touch "$G" '{"placeZoneId":"AREA_MAIN_GATE","space":"campus","visitorId":"e3000000-0000-4000-8000-000000000006"}'
t "online touch g immediate 429" 429 POST /api/world-online-touch "$G" '{"placeZoneId":"AREA_MAIN_GATE","space":"campus","visitorId":"e3000000-0000-4000-8000-000000000006"}'
COUNT1=$(curl -s "$BASE/api/world-online-count")
COUNT1_FLAGS=$(echo "$COUNT1" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('online',-1)>=1 and d.get('signedIn')==0 and d.get('guests')==d.get('online'))")
COUNT1_ASOF=$(echo "$COUNT1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('asOf',''))")
if [ "$COUNT1_FLAGS" = "True" ]; then pass=$((pass+1)); echo "PASS online count guests==online signedIn 0 -> $COUNT1"; else fail=$((fail+1)); echo "FAIL online count guests==online -> $COUNT1"; fi
COUNT2=$(curl -s "$BASE/api/world-online-count")
COUNT2_FLAGS=$(echo "$COUNT2" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('online',-1)>=1 and d.get('signedIn')==0 and d.get('guests')==d.get('online'))")
# The 5 s cache is Worker-local (per isolate): consecutive requests can land
# on different isolates with cold caches, so identical asOf is NOT asserted.
# The cache is a best-effort optimization, not a contract.
if [ "$COUNT2_FLAGS" = "True" ]; then pass=$((pass+1)); echo "PASS online count second read same shape -> $COUNT2"; else fail=$((fail+1)); echo "FAIL online count second read -> $COUNT2"; fi
t "online touch bad zone 400" 400 POST /api/world-online-touch "$E" '{"placeZoneId":"MAIN_HALL","space":"campus","visitorId":null}'
t "online touch bad space 400" 400 POST /api/world-online-touch "$F" '{"placeZoneId":null,"space":"moon","visitorId":null}'
t "online touch no session 401" 401 POST /api/world-online-touch "" '{"placeZoneId":null,"space":"campus","visitorId":null}'
t "online touch unknown 401" 401 POST /api/world-online-touch "$U" '{"placeZoneId":null,"space":"campus","visitorId":null}'
t "online touch h lobby 200" 200 POST /api/world-online-touch "$H" '{"placeZoneId":null,"space":"lobby","visitorId":null}'
t "online touch b lobby 200" 200 POST /api/world-online-touch "$B" '{"placeZoneId":null,"space":"lobby","visitorId":null}'
t "online touch get 405" 405 GET /api/world-online-touch "$G" ""
t "online count post 405" 405 POST /api/world-online-count "$G" '{}'
sleep 6
COUNT3=$(curl -s "$BASE/api/world-online-count")
COUNT3_FLAGS=$(echo "$COUNT3" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('online',-1)>=3 and d.get('signedIn')==0 and d.get('guests')==d.get('online'))")
if [ "$COUNT3_FLAGS" = "True" ]; then pass=$((pass+1)); echo "PASS online count after 3 touches -> $COUNT3"; else fail=$((fail+1)); echo "FAIL online count after 3 touches -> $COUNT3"; fi

# ---- BCD: B-3 guest NPC off (no handlers by design -> 404) ----
t "b3 npc-ai post 404" 404 POST /api/npc-ai "$A" '{}'
t "b3 npc-ai get 404" 404 GET /api/npc-ai "$A" ""
t "b3 npc-relationship post 404" 404 POST /api/npc-relationship "$A" '{}'
t "b3 npc-relationship get 404" 404 GET /api/npc-relationship "$A" ""
t "b3 world-quest post 404" 404 POST /api/world-quest "$A" '{}'
t "b3 world-quest get 404" 404 GET /api/world-quest "$A" ""
t "b3 model-convert post 404" 404 POST /api/model-convert "$A" '{}'
t "b3 npc-dialogue-route post 404" 404 POST /api/npc-dialogue-route "$A" '{}'

echo "curl: pass=$pass fail=$fail"
