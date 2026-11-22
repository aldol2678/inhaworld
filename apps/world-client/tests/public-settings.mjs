import assert from 'node:assert/strict';
import test from 'node:test';
import { publicSettings } from '../tools/public-settings.mjs';

test('unconfigured build keeps optional external services disabled', () => {
  assert.deepEqual(publicSettings({}), {siteOrigin:null,syncOrigin:null,firebase:null});
});
test('an external sync gateway is bound to one explicit site origin', () => {
  const sync = 'https://sync.example.invalid';
  assert.throws(() => publicSettings({WORLD_SYNC_ORIGIN:sync}));
  assert.throws(() => publicSettings({WORLD_PUBLIC_ORIGIN:sync+'/path'}));
  assert.equal(publicSettings({WORLD_PUBLIC_ORIGIN:'http://localhost:8080',WORLD_SYNC_ORIGIN:sync}).syncOrigin,sync);
});
test('server credentials cannot be serialized as Firebase Web App fields', () => {
  assert.throws(() => publicSettings({WORLD_PUBLIC_ORIGIN:'https://qa.example.invalid',
    WORLD_FIREBASE_WEB_CONFIG:JSON.stringify({private_key:'fixture'})}));
});

test('a copied Pages build ignores external services on a different origin', async () => {
  const { cp, mkdtemp, readFile, writeFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { pathToFileURL } = await import('node:url');
  const { execFileSync } = await import('node:child_process');
  const root = await mkdtemp(join(tmpdir(), 'world-origin-'));
  try {
    await writeFile(join(root, 'package.json'), '{"type":"module"}');
    for (const path of ['index.html', 'src', 'tools', 'map-sources', 'vendor', 'data']) {
      await cp(new URL('../' + path, import.meta.url), join(root, path), { recursive: true });
    }
    const site = 'https://world.example.invalid';
    const sync = 'https://sync.example.invalid';
    execFileSync(process.execPath, [join(root, 'tools/build-pages.mjs')], {
      env: { ...process.env, WORLD_PUBLIC_ORIGIN: site, WORLD_SYNC_ORIGIN: sync, WORLD_FIREBASE_WEB_CONFIG: '' },
    });
    const { settingsFor } = await import(pathToFileURL(join(root, 'dist/src/config.js')));
    assert.equal(settingsFor(site).syncOrigin, sync);
    assert.equal(settingsFor('https://preview.example.invalid'), null);
    assert.deepEqual(await readFile(join(root, 'dist/data/layout.bin')), await readFile(join(root, 'data/layout.bin')));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
