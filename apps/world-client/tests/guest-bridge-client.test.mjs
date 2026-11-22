import { test } from 'node:test';
import assert from 'node:assert/strict';
import { guestBridgeProof } from '../src/guest-bridge-proof.js';
function storage(entries={}) { return { getItem: k => entries[k] ?? null }; }
test('no guest id means no bridge attempt', () => assert.equal(guestBridgeProof(storage(), 'guest-profile'),null));
test('guest bearer credential is sent with profile candidate', () => assert.equal(guestBridgeProof(storage({'inhaworld-guest-session-v1':'guest-secret'}),'guest-secret'), 'guest-secret'));
test('authenticated device credential may prove same actor', () => assert.equal(guestBridgeProof(storage({'inhaworld-firebase-session-v1':'device-secret'}),'profile'),'device-secret'));
test('missing target skips stored proof', () => assert.equal(guestBridgeProof(storage({'inhaworld-firebase-session-v1':'device-secret'}),null),null));

test('unrelated guest does not supply proof', () => assert.equal(guestBridgeProof(storage({'inhaworld-guest-session-v1':'other-guest'}),'requested-profile'),null));
