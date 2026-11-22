import { guestBridgeProof } from './guest-bridge-proof.js';
// INHA WORLD — Firebase Auth client (DRAFT, portal integration patch).
// Talks to the Tier 4 Firebase Worker endpoints only; the Firebase JS SDK
// itself (signInWithEmailAndPassword / signInWithPopup / signInAnonymously)
// stays in the portal — this module only ever receives an ID token string
// from the caller (user.getIdToken()) and exchanges it for a Tier 4
// device session. No Firebase SDK import here, no apiKey here: the web
// apiKey lives in the portal's Firebase console web-app config, and the
// Worker only ever publishes {projectId, authDomain} via /config.
//
// Guest bridge rule: login sends guestSessionId = the known profile user id
// when one is stored (from an earlier me/profile call), otherwise the
// current guest session id. The profile user id is what the server links;
// a bare device-session id links nothing (the server then returns
// userId null and the profile is created later with /api/world-profile).
// Anonymous promotion needs no call here: the portal's linkWithCredential
// keeps the UID, and the next login upserts provider/email server-side.
//
// Storage keys (portal localStorage; the portal may pass its own store):
//   inhaworld-firebase-session-v1  device session id (X-Session-Id)
//   inhaworld-profile-user-v1      linked profile user id (or '')
//   inhaworld-guest-session-v1     current guest session id (pre-login)

const SESSION_KEY = 'inhaworld-firebase-session-v1';
const PROFILE_USER_KEY = 'inhaworld-profile-user-v1';
const GUEST_SESSION_KEY = 'inhaworld-guest-session-v1';

export class FirebaseAuthError extends Error {
  constructor(code, status) {
    super(code);
    this.name = 'FirebaseAuthError';
    this.code = code;
    this.status = status;
  }
}

function memoryStorage() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, v); },
    removeItem: (k) => { m.delete(k); },
  };
}

export function createFirebaseAuthClient(options = {}) {
  const baseUrl = String(options.baseUrl ?? '').replace(/\/$/, '');
  if (!baseUrl) throw new Error('createFirebaseAuthClient: baseUrl is required');
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== 'function') throw new Error('createFirebaseAuthClient: fetchImpl is required');
  const storage = options.storage ?? memoryStorage();

  async function call(path, { method = 'GET', sessionId = null, body = undefined } = {}) {
    const headers = { 'Content-Type': 'application/json' };
    if (sessionId) headers['X-Session-Id'] = sessionId;
    const res = await fetchImpl(`${baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = null; }
    if (!res.ok) {
      throw new FirebaseAuthError(
        (data && typeof data.error === 'string') ? data.error : 'FIREBASE_REQUEST_FAILED',
        res.status);
    }
    return data;
  }

  function getSessionId() { return storage.getItem(SESSION_KEY); }
  function getProfileUserId() { return storage.getItem(PROFILE_USER_KEY) || null; }
  function getGuestSessionId() { return storage.getItem(GUEST_SESSION_KEY) || null; }
  function setGuestSessionId(id) {
    if (id) storage.setItem(GUEST_SESSION_KEY, id);
    else storage.removeItem(GUEST_SESSION_KEY);
  }
  function clearLocalAuth() {
    // Account switching and expired sessions must not preserve an
    // unrelated profile/guest bearer for a later Firebase identity.
    for (const key of [SESSION_KEY, PROFILE_USER_KEY, GUEST_SESSION_KEY]) {
      storage.removeItem(key);
    }
  }

  // POST /api/auth/firebase/login {idToken, guestSessionId?}
  // Automatic guest bridging is best-effort: if a previously cached
  // proof is stale, sign in normally without linking another profile.
  // Explicit guestSessionId remains fail-closed (no silent retry).
  async function login(idToken, { guestSessionId = undefined } = {}) {
    if (typeof idToken !== 'string' || idToken === '') {
      throw new FirebaseAuthError('FIREBASE_TOKEN_MISSING', 400);
    }
    const guest = guestSessionId !== undefined
      ? guestSessionId
      : (getProfileUserId() ?? getGuestSessionId());
    const proof = guestBridgeProof(storage, guest);
    let data;
    if (guest && proof) {
      try {
        data = await call('/api/auth/firebase/login', {
          method: 'POST', sessionId: proof,
          body: { idToken, guestSessionId: guest },
        });
      } catch (error) {
        // The browser's local IDs are untrusted; do not make an otherwise
        // valid new login fail because a former account's proof expired.
        if (guestSessionId !== undefined || error?.status !== 403 ||
            error?.code !== 'GUEST_SESSION_PROOF_INVALID') throw error;
        clearLocalAuth();
        data = await call('/api/auth/firebase/login', {
          method: 'POST', body: { idToken },
        });
      }
    } else {
      data = await call('/api/auth/firebase/login', {
        method: 'POST', body: { idToken },
      });
    }
    if (typeof data?.deviceSessionId === 'string') {
      storage.setItem(SESSION_KEY, data.deviceSessionId);
    }
    if (typeof data?.userId === 'string') {
      storage.setItem(PROFILE_USER_KEY, data.userId);
    } else {
      storage.removeItem(PROFILE_USER_KEY);
    }
    storage.removeItem(GUEST_SESSION_KEY);
    return data;
  }

  // POST /api/auth/firebase/link {idToken} + X-Session-Id (guest session).
  // Links the guest's profile to the identity; the guest session keeps
  // working, so no new session is stored here.
  async function link(idToken) {
    const sessionId = getSessionId();
    if (!sessionId) throw new FirebaseAuthError('AUTH_REQUIRED', 401);
    if (typeof idToken !== 'string' || idToken === '') {
      throw new FirebaseAuthError('FIREBASE_TOKEN_MISSING', 400);
    }
    const data = await call('/api/auth/firebase/link', {
      method: 'POST', sessionId, body: { idToken },
    });
    if (typeof data?.userId === 'string') {
      storage.setItem(PROFILE_USER_KEY, data.userId);
    } else {
      storage.removeItem(PROFILE_USER_KEY);
    }
    storage.removeItem(GUEST_SESSION_KEY);
    return data;
  }

  // GET /api/auth/firebase/me (X-Session-Id). Refreshes the stored profile
  // user id when the server reports one.
  async function me() {
    const sessionId = getSessionId();
    if (!sessionId) throw new FirebaseAuthError('AUTH_REQUIRED', 401);
    const data = await call('/api/auth/firebase/me', { method: 'GET', sessionId });
    if (typeof data?.profileUserId === 'string') {
      storage.setItem(PROFILE_USER_KEY, data.profileUserId);
    }
    return data;
  }

  // POST /api/auth/firebase/logout (X-Session-Id). Clears the stored
  // device session id; the server deletes only the device row.
  async function logout() {
    const sessionId = getSessionId();
    if (!sessionId) {
      clearLocalAuth();
      return { ok: true };
    }
    const data = await call('/api/auth/firebase/logout', {
      method: 'POST', sessionId, body: {},
    });
    clearLocalAuth();
    return data;
  }

  // GET /api/auth/firebase/config (no session). {projectId, authDomain} only.
  async function config() {
    return call('/api/auth/firebase/config', { method: 'GET' });
  }

  return {
    login, link, me, logout, config,
    getSessionId, getProfileUserId, getGuestSessionId, setGuestSessionId,
    clearLocalAuth, SESSION_KEY, PROFILE_USER_KEY, GUEST_SESSION_KEY,
  };
}
