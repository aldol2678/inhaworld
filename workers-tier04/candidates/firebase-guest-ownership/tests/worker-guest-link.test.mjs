import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto as crypto } from 'node:crypto';
import { pathToFileURL } from 'node:url';
const UUIDS = Object.freeze({
  alice: '9ab6517d-99c2-4b47-bf37-043da3bec647',
  aliceDevice: '5ca27cd6-a89b-420d-bf9a-4a1b3043f04b',
  bob: '9d9161be-1a27-4112-b9d7-0684c7b54aaf',
  stale: '1916b5fb-648a-4cf0-aeeb-74f57f8437f3'
});
const root = new URL('../src/worker.js', import.meta.url);
const code = (await readFile(root, 'utf8')).replace(
  "import { neon } from '@neondatabase/serverless';",
  'const neon = globalThis.__stubNeon;');
assert.notEqual(code.includes('const neon = globalThis.__stubNeon;'), false);
globalThis.__stubNeon = (...args) => globalThis.__stubNeonImpl(...args);
const Worker = (await import('data:text/javascript;base64,' + Buffer.from(code).toString('base64'))).default;
const key = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' }, true, ['sign','verify']);
const pub = await crypto.subtle.exportKey('jwk', key.publicKey);
const jwks = JSON.stringify({keys: [{...pub, kid: 'fixture-guest-bridge', use: 'sig', alg: 'RS256'}]});
const base64url = (x)=>Buffer.from(x).toString('base64url');
const projectId = 'test-guest-bridge';
async function token(uid='firebase-test-alice') {
  const now=Math.floor(Date.now()/1000);
  const head=base64url(JSON.stringify({alg:'RS256',kid:'fixture-guest-bridge',typ:'JWT'}));
  const body=base64url(JSON.stringify({aud:projectId,iss:'https://securetoken.google.com/'+projectId,sub:uid,iat:now-3,exp:now+300,firebase:{sign_in_provider:'anonymous'}}));
  const sig=await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key.privateKey,new TextEncoder().encode(head+'.'+body));
  return head+'.'+body+'.'+base64url(Buffer.from(sig));
}
let db;
function resetDB() {
  db={
    sessions:new Map([
      [UUIDS.alice,{id:UUIDS.alice,actorUserId:null,createdEpoch:1,epoch:1}],
      [UUIDS.aliceDevice,{id:UUIDS.aliceDevice,actorUserId:UUIDS.alice,createdEpoch:1,epoch:1}],
      [UUIDS.bob,{id:UUIDS.bob,actorUserId:null,createdEpoch:1,epoch:1}],
      [UUIDS.stale,{id:UUIDS.stale,actorUserId:null,createdEpoch:0,epoch:1}],
    ]), links:[],issues:[]
  };
  globalThis.__stubNeonImpl=()=>async (parts,...values)=>{
    const sql=parts.join('?');
    if(sql.includes('from public.sessions s cross join private.world_auth_epoch')) {
      const session=db.sessions.get(values[0]);return session?[session]:[];
    }
    if(sql.includes('link_firebase_identity_v2')) {
      db.links.push(values);
      return [{result:{profileUserId: values[4], isNewIdentity:true, provider:values[1], email:null, emailVerified:false}}];
    }
    if(sql.includes('issue_world_firebase_session_v1')) {
      db.issues.push(values);return [{result:{sessionId: values[1]}}];
    }
    throw new Error('unexpected SQL ' + sql.slice(0,180));
  };
}
const env={DATABASE_URL:'mock',FIREBASE_PROJECT_ID:projectId,FIREBASE_JWKS_JSON:jwks};
async function request(path,idToken,guestSessionId=undefined,proof=undefined){
  const body={idToken}; if(guestSessionId!==undefined)body.guestSessionId=guestSessionId;
  const headers={'content-type':'application/json','origin':'https://fixture.example','host':'fixture.example'};
  if(proof)headers['x-session-id']=proof;
  const res=await Worker.fetch(new Request('https://fixture.example'+path,{method:'POST',headers,body:JSON.stringify(body)}),env);
  return {status:res.status,body:await res.json()};
}
for(const [name,guest,proof,expected] of [
  ['missing bearer cannot bridge',UUIDS.alice,undefined,403],
  ['wrong owner cannot bridge',UUIDS.alice,UUIDS.bob,403],
  ['stale session cannot bridge',UUIDS.stale,UUIDS.stale,403],
  ['unknown session cannot bridge',UUIDS.alice,'1cb7869e-2267-4c9f-a875-1698f0d0e92a',403],
  ['other owner via account session is refused',UUIDS.bob,UUIDS.aliceDevice,403],
  ['malformed profile UUID is invalid', 'not-a-uuid',UUIDS.alice,400],
]){
  test(name, async ()=>{resetDB();const r=await request('/api/auth/firebase/login',await token(),guest,proof);assert.equal(r.status,expected);assert.equal(db.links.length,0);assert.equal(db.issues.length,0)});
}
test('existing matching guest session preserves guest bridge',async()=>{
  resetDB();const r=await request('/api/auth/firebase/login',await token(),UUIDS.alice,UUIDS.alice);
  assert.equal(r.status,200);assert.equal(r.body.userId,UUIDS.alice);assert.equal(db.links.length,1);assert.equal(db.links[0][4],UUIDS.alice);assert.equal(db.links[0][5],UUIDS.alice);assert.equal(db.issues.length,1);
});
test('an authorized actor device may reauthenticate its own profile',async()=>{
  resetDB();const r=await request('/api/auth/firebase/login',await token(),UUIDS.alice,UUIDS.aliceDevice);
  assert.equal(r.status,200);assert.equal(db.links[0][5],UUIDS.aliceDevice);
});
test('normal Firebase login needs no guest bridge',async()=>{
  resetDB();const r=await request('/api/auth/firebase/login',await token(),undefined,undefined);
  assert.equal(r.status,200);assert.equal(db.links.length,1);assert.equal(db.links[0][4],null);assert.equal(db.links[0][5],null);
});
test('explicit /link passes verified actor and proof',async()=>{
  resetDB();const r=await request('/api/auth/firebase/link',await token(),undefined,UUIDS.alice);
  assert.equal(r.status,200);assert.equal(db.links.length,1);assert.equal(db.links[0][4],UUIDS.alice);assert.equal(db.links[0][5],UUIDS.alice);
});
test('linking from another account session uses only its own actor',async()=>{
  resetDB();const r=await request('/api/auth/firebase/link',await token(),undefined,UUIDS.aliceDevice);
  assert.equal(r.status,200);assert.equal(db.links[0][4],UUIDS.alice);assert.equal(db.links[0][5],UUIDS.aliceDevice);
});
