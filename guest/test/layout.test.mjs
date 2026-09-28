// The page's layout, measured in a real browser: jsdom has no layout, and the port's frame shrinking to
// an iframe's default 150px (found on Gordon's v1) only shows where a browser lays the page out. Runs
// headless Chrome when it is installed; skipped otherwise.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const page = new URL('../invite.html', import.meta.url);

/// The page with its bundle swapped for a probe that shows the port and reports sizes in the title.
function measure(width, height) {
  const probe = `<script>addEventListener('load', () => {
    document.getElementById('port').hidden = false;
    document.getElementById('gate').hidden = true;
    const h = (id) => Math.round(document.getElementById(id).getBoundingClientRect().height);
    document.title = JSON.stringify({ frame: h('frame'), body: h('body') });
  });</script>`;
  const html = readFileSync(page, 'utf8').replace(/<script type="module"[^>]*><\/script>/, probe);
  const file = join(mkdtempSync(join(tmpdir(), 'port42-layout-')), 'page.html');
  writeFileSync(file, html);
  return new Promise((resolve, reject) => {
    execFile(CHROME, ['--headless=new', '--disable-gpu', `--window-size=${width},${height}`,
      '--virtual-time-budget=2000', '--dump-dom', `file://${file}`], { timeout: 170_000 }, (err, out) => {
      if (err) return reject(err);
      const m = out.match(/<title>([^<]*)<\/title>/);
      resolve(JSON.parse(m[1].replace(/&quot;/g, '"')));
    });
  });
}

test('the port fills the page under the bar, on a laptop and on a phone', { skip: !existsSync(CHROME) && 'no Chrome', timeout: 180_000 }, async () => {
  for (const [w, h] of [[1280, 800], [390, 844]]) {
    const { frame, body } = await measure(w, h);
    assert.ok(body > 300, `the body is ${body}px at ${w}x${h}`);
    assert.equal(frame, body, `the port is ${frame}px of ${body}px at ${w}x${h}`);
  }
});
