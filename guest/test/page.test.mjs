// The invite page, in a browser DOM (jsdom): what it does before and after the person chooses.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { start } from '../src/page.js';
import { Guest } from '../src/guest.js';
import { Refusal } from '../src/client.js';

const html = readFileSync(new URL('../invite.html', import.meta.url), 'utf8').replace(/<script[^>]*><\/script>/, '');
const coupon = { v: 1, host: 'a'.repeat(52), relays: ['wss://relay.test/v1'], port: 'P', rights: ['see', 'use'],
                 nonce: 'nonce-1', exp: Math.floor(Date.now() / 1000) + 600, hostName: 'Gordon', portTitle: 'chart', code: false };
const fragment = (c) => Buffer.from(JSON.stringify(c)).toString('base64url');

function page(c = coupon, extra = '') {
  const dom = new JSDOM(html, { url: 'https://open.port42.ai/' + extra + '#' + (c ? fragment(c) : 'not-a-coupon'),
                                 pretendToBeVisual: true });
  const calls = [];
  let connects = 0;
  const session = {
    onEnd: null,
    call(method, args) {
      calls.push({ method, args });
      if (method === 'port.getHtml') return Promise.resolve('<p>the port</p>');
      if (method === 'chat.read') return Promise.resolve({ entries: [{ seq: 1, text: 'hi', from: { name: 'Gordon' } }] });
      if (method === 'port.subscribe') return new Promise(() => {});
      return Promise.resolve({ ok: true });
    },
    close() {},
  };
  const connect = async () => { connects++; return session; };
  const storage = new Map();
  const store = { getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v) };
  const app = start({ win: dom.window, doc: dom.window.document, storage: store, connect });
  return { dom, doc: dom.window.document, calls, session, storage, app, connects: () => connects };
}

const settle = () => new Promise((r) => setTimeout(r, 20));

test('before a click it reads the invite, clears it from the address bar, and connects to nothing', () => {
  const p = page();
  assert.equal(p.connects(), 0, 'the page connected before the person chose');
  assert.equal(p.dom.window.location.hash, '', 'the invite stayed in the address bar');
  assert.match(p.doc.getElementById('who').textContent, /Gordon shared 'chart' with you/);
  assert.match(p.doc.getElementById('what').textContent, /see and use/);
  assert.equal(p.doc.getElementById('intro').hidden, false);
  assert.match(p.doc.getElementById('open-app').href, /^port42:\/\/invite#/);
  assert.match(p.doc.getElementById('get-app').href, /Port42\.dmg$/);
});

test('a link that is not an invite says so', () => {
  const p = page(null);
  assert.equal(p.doc.getElementById('broken').hidden, false);
  assert.equal(p.connects(), 0);
});

test('joining redeems the invite as the name given, then shows the port in a frame that holds no key', async () => {
  const p = page();
  p.doc.getElementById('open-here').click();
  p.doc.getElementById('name').value = 'Ada';
  p.doc.getElementById('join-form').dispatchEvent(new p.dom.window.Event('submit', { cancelable: true }));
  await settle();
  assert.equal(p.connects(), 1);
  assert.deepEqual(p.calls[0], { method: 'invite.redeem', args: { nonce: 'nonce-1', name: 'Ada' } });
  assert.equal(p.doc.getElementById('port').hidden, false);
  const frame = p.doc.getElementById('frame');
  assert.ok(!frame.getAttribute('sandbox').includes('allow-same-origin'), 'the frame can reach the page\'s storage');
  assert.match(frame.getAttribute('src'), /^frame\.html/, 'the port is not loaded in its own document');
  const sent = p.app.frameState.html;
  assert.match(sent, /<p>the port<\/p>/);
  assert.match(sent, /port42\.self|self: Object\.freeze/, 'the frame has no window.port42');
  const seed = p.storage.get('port42.guest.seed');
  assert.ok(seed && !sent.includes(seed), 'the guest\'s key is inside the frame');
  assert.match(p.doc.getElementById('chat-list').textContent, /Gordon hi/);
});

test('the frame\'s calls go to the host named as the registry names them; unknown ones are refused', async () => {
  const calls = [];
  const g = new Guest({ coupon, storage: null, ui: {}, connect: async () => ({}) });
  g.session = { call: (m, a) => { calls.push({ m, a }); return Promise.resolve('ok'); } };
  await g.frameCall('port.push', ['P', { n: 1 }, 't:1']);
  assert.deepEqual(calls[0], { m: 'port.push', a: { id: 'P', data: { n: 1 }, token: 't:1' } });
  await assert.rejects(g.frameCall('terminal.exec', ['ls']), (e) => e.code === 'not_granted');
});

test('when the host goes away the port dims, the chat stops, and it says why', async () => {
  const p = page();
  p.doc.getElementById('open-here').click();
  p.doc.getElementById('name').value = 'Ada';
  p.doc.getElementById('join-form').dispatchEvent(new p.dom.window.Event('submit', { cancelable: true }));
  await settle();
  p.app.guest().retryMs = 60_000;
  p.session.onEnd(new Refusal('host_offline', 'gone'));
  assert.ok(p.doc.body.classList.contains('offline'));
  assert.equal(p.doc.getElementById('chat-input').disabled, true);
  assert.match(p.doc.getElementById('status').textContent, /Gordon's Mac is offline/);
  p.app.guest().stop();
});

test('an invite refused by the host is explained, and the person can try again', async () => {
  const p = page();
  p.session.call = (m) => m === 'invite.redeem' ? Promise.reject(Object.assign(new Refusal('invite_invalid', 'used'), { reason: 'used' })) : Promise.resolve();
  p.doc.getElementById('open-here').click();
  p.doc.getElementById('name').value = 'Ada';
  p.doc.getElementById('join-form').dispatchEvent(new p.dom.window.Event('submit', { cancelable: true }));
  await settle();
  assert.match(p.doc.getElementById('join-error').textContent, /already been used/);
  assert.equal(p.doc.getElementById('join-button').disabled, false);
});
