// A shared port in the browser is wrapped as the app wraps it (GM, 2026-09-27: it rendered in Times,
// and a page that awaits at top level never ran, so its data was missing).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { framedPage, BASE_CSS } from '../src/shim.js';

test('the page gets the base style and a document around it', () => {
  const out = framedPage('p1', '<h1>hi</h1>');
  assert.match(out, /<style data-port42>[\s\S]*font-family: "SF Mono"[\s\S]*<\/style>/);
  assert.ok(out.startsWith('<!DOCTYPE html>') && out.includes('<body><h1>hi</h1></body>'));
  assert.ok(BASE_CSS.includes('monospace'));
});

test('its scripts run as modules, as in the app; the shim stays a classic script and comes first', () => {
  const out = framedPage('p1', '<script>const v = await port42.storage.get("state");</script>');
  assert.ok(out.includes('<script type="module">const v = await'), 'a top-level await would be a syntax error');
  const shim = out.indexOf('window.port42'), page = out.indexOf('type="module"');
  assert.ok(shim > 0 && shim < page, 'the shim must be defined before the page runs');
});
