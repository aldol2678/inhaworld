// Public preference values are shared with inhagame. Runtime controls are Three.js specific.
const registryKey = 'inhagame-device-settings-v2';
const mirrorKey = 'inha-world-graphics-quality-v1';
export const profiles = Object.freeze({
  very_low: { label: '매우 낮음', pixelCap: 0.65, distance: 57, detail: 0, antialias: false },
  low: { label: '낮음', pixelCap: 0.8, distance: 78, detail: 1, antialias: false },
  medium: { label: '중간', pixelCap: 1.25, distance: 100, detail: 2, antialias: false },
  high: { label: '높음', pixelCap: 2, distance: 120, detail: 3, antialias: true },
  ultra: { label: '울트라', pixelCap: 2, distance: 154, detail: 4, antialias: true },
});
const tiers = Object.keys(profiles);
const valid = (value) => value === 'auto' || Object.hasOwn(profiles, value);

function registry(storage) {
  try {
    const data = JSON.parse(storage?.getItem(registryKey));
    if (data?.schemaVersion === 2 && typeof data.graphics === 'object' && data.graphics !== null) return data;
  } catch {
    /* A pre-registry or session-only client can still play. */
  }
}
export function readQuality(storage) {
  // PlayCanvas reconciles a valid v1 mirror over the shared v2 document.
  try {
    const mirror = storage?.getItem(mirrorKey);
    if (valid(mirror)) return mirror;
  } catch {
    /* Session-only. */
  }
  const current = registry(storage)?.graphics.quality;
  return valid(current) ? current : 'auto';
}
function saveQuality(storage, value) {
  const current = registry(storage);
  try {
    if (current) {
      current.graphics.quality = value;
      storage.setItem(registryKey, JSON.stringify(current));
    }
    storage?.setItem(mirrorKey, value);
  } catch {
    /* Keep the selected profile for this session. */
  }
}

export function initialTier({ width, height, dpr, touch, maxTextureSize }) {
  const pixels = width * height * dpr ** 2;
  if (maxTextureSize < 4096 || pixels > 5e6) return 'low';
  if (touch) return pixels < 1.2e6 && maxTextureSize >= 8192 ? 'medium' : 'low';
  return pixels <= 2.5e6 && maxTextureSize >= 8192 ? 'high' : 'medium';
}

export function createQuality({ device, storage, apply }) {
  let preference = readQuality(storage);
  let tier = preference === 'auto' ? initialTier(device()) : preference;
  let last, elapsed, slow, fast, cooldown;
  const samples = [];
  function reset(hold = 0) {
    last = null;
    samples.length = elapsed = slow = fast = 0;
    cooldown = hold;
  }
  function select(value) {
    if (!valid(value)) return;
    preference = value;
    tier = value === 'auto' ? initialTier(device()) : value;
    reset();
    saveQuality(storage, value);
    apply(tier, preference);
  }
  function frame(now) {
    if (preference !== 'auto') return;
    const interval = last === null ? 0 : now - last;
    last = now;
    if (interval <= 0) return;
    if (interval > 3000) {
      reset(cooldown);
      return;
    } // tab suspension / debugger pause
    const dt = Math.min(250, interval);
    if (cooldown > 0) {
      cooldown -= dt;
      return;
    }
    samples.push(dt);
    elapsed += dt;
    if (elapsed < 2000 || samples.length < 8) return;
    samples.sort((a, b) => a - b);
    const p75 = samples[Math.ceil(samples.length * 0.75) - 1];
    samples.length = elapsed = 0;
    slow = p75 > 29 ? slow + 1 : 0;
    fast = p75 < 19 ? fast + 1 : 0;
    const index = tiers.indexOf(tier);
    const ceiling = device().touch ? tiers.indexOf('high') : tiers.length - 1;
    const lower = slow >= 2 && index > 0;
    const higher = fast >= 5 && index < ceiling;
    if (lower || higher) {
      tier = tiers[index + (lower ? -1 : 1)];
      reset(lower ? 14000 : 8000);
      apply(tier, preference);
    }
  }
  reset();
  apply(tier, preference);
  return {
    select,
    frame,
    resume: () => reset(cooldown),
    get tier() {
      return tier;
    },
    get preference() {
      return preference;
    },
  };
}
