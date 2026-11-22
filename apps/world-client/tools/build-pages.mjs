// Build a standalone Pages root with no network access.
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { publicSettings } from './public-settings.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const settings = publicSettings(process.env);
const out = join(root, 'dist');
const stage = await mkdtemp(join(root, '.pages-build-'));
const next = join(stage, 'next');
const previous = join(stage, 'previous');

try {
  await mkdir(join(next, 'data'), { recursive: true });
  for (const name of ['index.html', 'src', 'vendor', 'data/rooms.json', 'data/quests.json']) {
    await cp(join(root, name), join(next, name), { recursive: true });
  }
  await writeFile(join(next, 'public-config.js'), 'export default ' + JSON.stringify(settings) + ';\n');
  execFileSync(process.execPath, [join(root, 'tools/build-layout.mjs')], {
    env: { ...process.env, WORLD_LAYOUT_OUT: join(next, 'data') },
    stdio: 'inherit',
  });

  let hadPrevious = true;
  try {
    await rename(out, previous);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    hadPrevious = false;
  }
  try {
    await rename(next, out);
  } catch (error) {
    if (hadPrevious && error.code !== 'ENOTEMPTY' && error.code !== 'EEXIST') {
      await rename(previous, out);
    }
    throw error;
  }
  console.log('Pages static root: dist');
} finally {
  await rm(stage, { recursive: true, force: true });
}
