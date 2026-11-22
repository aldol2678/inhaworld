import settings from '../public-config.js';

// A copied production build (for example a PR preview) must not use the
// original site's external services. Same-origin API requests stay local.
export function settingsFor(origin) {
  return settings.siteOrigin && settings.siteOrigin === origin ? settings : null;
}
