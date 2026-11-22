import assert from 'node:assert/strict';
import test from 'node:test';
import { createFirebaseAuthClient } from '../src/firebase-auth-client.js';

const S = 'inhaworld-firebase-session-v1';
const P = 'inhaworld-profile-user-v1';
const G = 'inhaworld-guest-session-v1';
const PROFILE = '00000000-0000-4000-8000-000000000011';
const PROOF = '00000000-0000-4000-8000-000000000022';

function fixture(seed, reply) {
  const records = new Map(Object.entries(seed));
  const storage = {
    getItem: k => records.get(k) ?? null,
    setItem: (k,v) => records.set(k,v),
    removeItem: k => records.delete(k),
  };
  const calls = [];
  const client = createFirebaseAuthClient({
    baseUrl: 'https://qa.example.invalid', storage,
    fetchImpl: async (url, options) => {
      const request = {path: new URL(url).pathname, headers: options.headers, body: options.body ? JSON.parse(options.body) : null};
      calls.push(request);
      const {status, data} = reply(request, calls.length);
      return {ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(data)};
    },
  });
  return {client, calls, records};
}

test('stale implicit proof retries once as ordinary login and clears previous profile', async () => {
  const {client,calls,records} = fixture({[S]:PROOF,[P]:PROFILE}, (_,n) => n===1
    ? {status:403,data:{error:'GUEST_SESSION_PROOF_INVALID'}}
    : {status:200,data:{deviceSessionId:'fresh',userId:null}});
  await client.login('fixture-id-token');
  assert.equal(calls.length,2);
  assert.equal(calls[0].headers['X-Session-Id'],PROOF);
  assert.equal(calls[0].body.guestSessionId,PROFILE);
  assert.deepEqual(calls[1].body,{idToken:'fixture-id-token'});
  assert.equal(calls[1].headers['X-Session-Id'],undefined);
  assert.equal(records.get(S),'fresh');
  assert.equal(records.has(P),false);
  assert.equal(records.has(G),false);
});

test('explicit guest link stays fail closed when its proof is wrong',async()=>{
  const {client,calls}=fixture({[S]:PROOF,[P]:PROFILE},()=>({status:403,data:{error:'GUEST_SESSION_PROOF_INVALID'}}));
  await assert.rejects(()=>client.login('fixture-token',{guestSessionId:PROFILE}),
    e=>e.status===403&&e.code==='GUEST_SESSION_PROOF_INVALID');
  assert.equal(calls.length,1);
});

test('correct guest session proof attaches only its matching profile',async()=>{
  const {client,calls,records}=fixture({[P]:PROFILE,[G]:PROFILE},()=>({status:200,data:{deviceSessionId:'fresh',userId:PROFILE}}));
  await client.login('fixture-token');
  assert.equal(calls.length,1);
  assert.equal(calls[0].headers['X-Session-Id'],PROFILE);
  assert.equal(calls[0].body.guestSessionId,PROFILE);
  assert.equal(records.get(P),PROFILE);
  assert.equal(records.has(G),false);
});

test('unrelated guest credential is not sent as a proof',async()=>{
  const {client,calls,records}=fixture({[P]:PROFILE,[G]:PROOF},()=>({status:200,data:{deviceSessionId:'fresh',userId:null}}));
  await client.login('fixture-token');
  assert.equal(calls[0].headers['X-Session-Id'],undefined);
  assert.deepEqual(calls[0].body,{idToken:'fixture-token'});
  assert.equal(records.has(P),false);
});

test('logout removes stale account, profile and guest session even when no device exists',async()=>{
  const {client,records,calls}=fixture({[P]:PROFILE,[G]:PROOF},()=>{throw Error('unexpected request')});
  await client.logout();
  assert.equal(calls.length,0);
  for(const k of [S,P,G])assert.equal(records.has(k),false);
});

test('logout after server confirmation removes all cached identity',async()=>{
  const {client,records}=fixture({[S]:PROOF,[P]:PROFILE,[G]:PROOF},()=>({status:200,data:{ok:true}}));
  await client.logout();
  for(const k of [S,P,G])assert.equal(records.has(k),false);
});

test('successful link returning null userId clears obsolete profile',async()=>{
  const {client,records}=fixture({[S]:PROOF,[P]:PROFILE,[G]:PROOF},()=>({status:200,data:{userId:null}}));
  await client.link('fixture-token');
  assert.equal(records.has(P),false);
  assert.equal(records.has(G),false);
});
