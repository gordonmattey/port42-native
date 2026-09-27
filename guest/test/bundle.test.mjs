// The committed bundle is what the source builds to, and the page names its hash, so what is served
// is what was reviewed and a changed script is refused by the browser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';

const root = new URL('..', import.meta.url);

test('dist/port42-guest.js is a fresh build of src, and invite.html names its hash', async () => {
  const out = await build({ entryPoints: [new URL('src/main.js', root).pathname], bundle: true, format: 'esm',
                            minify: true, write: false, logLevel: 'silent' });
  const fresh = out.outputFiles[0].contents;
  const committed = readFileSync(new URL('dist/port42-guest.js', root));
  assert.ok(Buffer.from(fresh).equals(committed), 'the bundle is stale: run npm run build in guest/');
  const hash = 'sha384-' + createHash('sha384').update(committed).digest('base64');
  const page = readFileSync(new URL('invite.html', root), 'utf8');
  assert.ok(page.includes(`integrity="${hash}"`), 'invite.html does not name the bundle\'s hash');
});
