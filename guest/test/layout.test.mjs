// The page's layout, measured in a real browser: jsdom has no layout, and the port's frame shrinking to
// an iframe's default 150px (found on Gordon's v1) only shows where a browser lays the page out. Runs
// headless Chrome when it is installed; skipped otherwise.
//
// CHROME MUST NEVER OUTLIVE THE TEST. This used execFile with a timeout: on timeout Node sent SIGTERM,
// headless Chrome and its helpers survived it, and the test never exited. Two runs sat for 10 and 18
// hours holding Chromes. Chrome now runs detached in its own process group with a throwaway profile,
// the whole group gets SIGKILL on timeout and again in a finally, and the profile is removed.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const page = new URL('../invite.html', import.meta.url);

/// The profiles this run gave Chrome, so the stray check looks only at our own processes.
const profiles = [];

/// Kills Chrome's whole process group; it is gone already when this throws.
function killGroup(pid) {
  try { process.kill(-pid, 'SIGKILL'); } catch {}
}

/// Loads `html` in headless Chrome and returns the dumped DOM. Rejects, with every Chrome process
/// killed, if it has not finished within `timeoutMs`.
export async function dumpDom(html, { width, height, timeoutMs = 60_000 }) {
  const dir = mkdtempSync(join(tmpdir(), 'port42-layout-'));
  const file = join(dir, 'page.html');
  const profile = join(dir, 'profile');
  profiles.push(profile);
  writeFileSync(file, html);
  let child;
  try {
    return await new Promise((resolve, reject) => {
      child = spawn(CHROME, ['--headless=new', '--disable-gpu', `--user-data-dir=${profile}`,
        // A fresh profile would ask the login keychain for Chrome's storage key, a prompt headless
        // Chrome can never answer; the mock keychain keeps it off the user's keychain entirely.
        '--use-mock-keychain', '--password-store=basic',
        '--no-first-run', '--no-default-browser-check', `--window-size=${width},${height}`,
        '--virtual-time-budget=2000', '--dump-dom', `file://${file}`],
        { detached: true, stdio: ['ignore', 'pipe', 'ignore'] });
      let out = '';
      // Done when the DOM is out. With its own profile Chrome prints the page and then stays up (its
      // background work on a new profile), so waiting for it to exit would always hit the timeout.
      child.stdout.on('data', (d) => {
        out += d;
        if (out.includes('</html>')) { clearTimeout(timer); killGroup(child.pid); resolve(out); }
      });
      const timer = setTimeout(() => {
        killGroup(child.pid);
        reject(new Error(`headless Chrome did not finish in ${timeoutMs} ms; killed`));
      }, timeoutMs);
      child.on('error', (e) => { clearTimeout(timer); reject(e); });
      child.on('close', (code) => {
        clearTimeout(timer);
        code === 0 ? resolve(out) : reject(new Error(`headless Chrome exited ${code}`));
      });
    });
  } finally {
    if (child?.pid) killGroup(child.pid);
    rmSync(dir, { recursive: true, force: true });
  }
}

/// The page with its bundle swapped for a probe that shows the port and reports sizes in the title.
async function measure(width, height) {
  const probe = `<script>addEventListener('load', () => {
    document.getElementById('port').hidden = false;
    document.getElementById('gate').hidden = true;
    const h = (id) => Math.round(document.getElementById(id).getBoundingClientRect().height);
    document.title = JSON.stringify({ frame: h('frame'), body: h('body') });
  });</script>`;
  const html = readFileSync(page, 'utf8').replace(/<script type="module"[^>]*><\/script>/, probe);
  const out = await dumpDom(html, { width, height, timeoutMs: 80_000 });
  const m = out.match(/<title>([^<]*)<\/title>/);
  return JSON.parse(m[1].replace(/&quot;/g, '"'));
}

/// Chrome processes still running on a profile this run created.
function strayChromes() {
  return profiles.map((p) => {
    try { return execFileSync('/usr/bin/pgrep', ['-f', 'user-data-dir=' + p]).toString().trim(); }
    catch { return ''; }   // pgrep exits 1 when nothing matches
  }).filter(Boolean).join(' ');
}

test('the port fills the page under the bar, on a laptop and on a phone', { skip: !existsSync(CHROME) && 'no Chrome', timeout: 180_000 }, async () => {
  for (const [w, h] of [[1280, 800], [390, 844]]) {
    const { frame, body } = await measure(w, h);
    assert.ok(body > 300, `the body is ${body}px at ${w}x${h}`);
    assert.equal(frame, body, `the port is ${frame}px of ${body}px at ${w}x${h}`);
  }
  assert.equal(strayChromes(), '', 'headless Chrome outlived the test');
});

// A page that never settles fails the run inside its timeout and leaves no Chrome behind: the case
// that used to hang for hours.
test('a page that never settles is killed at the timeout, with no Chrome left', { skip: !existsSync(CHROME) && 'no Chrome', timeout: 60_000 }, async () => {
  const started = Date.now();
  await assert.rejects(dumpDom('<html><body><script>for (;;) {}</script></body></html>',
    { width: 800, height: 600, timeoutMs: 8_000 }), /did not finish/);
  assert.ok(Date.now() - started < 20_000, `took ${Date.now() - started} ms to give up`);
  await new Promise((r) => setTimeout(r, 500));   // the kernel reaps the killed group
  assert.equal(strayChromes(), '', 'a killed Chrome is still running');
});
