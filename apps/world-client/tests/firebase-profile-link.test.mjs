import assert from 'node:assert/strict';
import test from 'node:test';
import { linkNewFirebaseProfile } from '../src/firebase-profile-link.js';

const uid = 'qa-firebase-uid-1';
const profileId = '33f8787a-51b3-4d24-a9aa-9a32afed69b5';
const profile = { userId: profileId, nickname: 'QaTestP9' };
const firebaseUser = { uid, getIdToken: async () => 'fixture-token' };

test('new Firebase profile is reported linked only after verified readback', async () => {
  const calls = [];
  const authClient = {
    me: async () => {
      calls.push('me');
      return calls.length === 1
        ? {guest: true, firebaseUid: null}
        : {guest: false, firebaseUid: uid, profileUserId: profileId};
    },
    link: async (token) => {
      calls.push('link');
      assert.equal(token,'fixture-token');
      return {userId:profileId};
    },
  };
  const result=await linkNewFirebaseProfile({profile,firebaseUser,authClient});
  assert.equal(result.profileUserId,profileId);
  assert.deepEqual(calls,['me','link','me']);
});

test('old device session belonging to another Firebase UID is rejected before linking', async () => {
  let linked=false;
  const authClient={
    me:async()=>({guest:false,firebaseUid:'another-uid',profileUserId:profileId}),
    link:async()=>{linked=true; return {userId:profileId};},
  };
  await assert.rejects(()=>linkNewFirebaseProfile({profile,firebaseUser,authClient}),
    e=>e.code==='FIREBASE_ACCOUNT_MISMATCH');
  assert.equal(linked,false);
});

test('missing Firebase account cannot link a profile', async () => {
  await assert.rejects(()=>linkNewFirebaseProfile({profile,firebaseUser:null,authClient:{}}),
    e=>e.code==='FIREBASE_SIGNIN_REQUIRED');
});

test('profile ID is required before linking', async () => {
  await assert.rejects(()=>linkNewFirebaseProfile({profile:{},firebaseUser,authClient:{}}),
    e=>e.code==='PROFILE_ID_MISSING');
});

test('link result must match the newly created game profile', async () => {
  const authClient={
    me:async()=>({guest:true}),
    link:async()=>({userId:'another-profile'}),
  };
  await assert.rejects(()=>linkNewFirebaseProfile({profile,firebaseUser,authClient}),
    e=>e.code==='PROFILE_LINK_MISMATCH');
});

test('server readback must confirm the identity, not just the link response', async () => {
  let reads=0;
  const authClient={
    me:async()=>++reads===1?{guest:true}:{guest:true,profileUserId:profileId},
    link:async()=>({userId:profileId}),
  };
  await assert.rejects(()=>linkNewFirebaseProfile({profile,firebaseUser,authClient}),
    e=>e.code==='PROFILE_LINK_READBACK_FAILED');
});

test('readback with an unexpected Firebase UID fails', async () => {
  let reads=0;
  const authClient={
    me:async()=>++reads===1?{guest:true}:{guest:false,firebaseUid:'other',profileUserId:profileId},
    link:async()=>({userId:profileId}),
  };
  await assert.rejects(()=>linkNewFirebaseProfile({profile,firebaseUser,authClient}),
    e=>e.code==='PROFILE_LINK_READBACK_FAILED');
});

test('existing linked identity on the same Firebase user can be confirmed', async () => {
  let reads=0;
  const authClient={
    me:async()=>{reads++;return {guest:false,firebaseUid:uid,profileUserId:profileId};},
    link:async()=>({userId:profileId}),
  };
  await linkNewFirebaseProfile({profile,firebaseUser,authClient});
  assert.equal(reads,2);
});
