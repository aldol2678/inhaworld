function readOrigin(value) {
  if (!value) return null;
  const url = new URL(value);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (value !== url.origin || !(url.protocol === 'https:' || (local && url.protocol === 'http:'))) {
    throw new Error('Use a complete HTTPS origin (HTTP is accepted on loopback)');
  }
  return url.origin;
}

export function publicSettings(env) {
  const siteOrigin = readOrigin(env.WORLD_PUBLIC_ORIGIN);
  const syncOrigin = readOrigin(env.WORLD_SYNC_ORIGIN);
  let firebase = null;
  if (env.WORLD_FIREBASE_WEB_CONFIG) {
    firebase = JSON.parse(env.WORLD_FIREBASE_WEB_CONFIG);
    const allowed = ['apiKey', 'authDomain', 'projectId', 'appId', 'storageBucket', 'messagingSenderId', 'measurementId'];
    if (!firebase || Array.isArray(firebase) || typeof firebase !== 'object' ||
        !['apiKey', 'authDomain', 'projectId', 'appId'].every(k => firebase[k]) ||
        !Object.entries(firebase).every(([k,v]) => allowed.includes(k) && typeof v === 'string')) {
      throw new Error('Expected Firebase public Web App settings only');
    }
  }
  if ((firebase || syncOrigin) && !siteOrigin) throw new Error('WORLD_PUBLIC_ORIGIN is required for remote services');
  return {siteOrigin, syncOrigin, firebase};
}
