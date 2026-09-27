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

function page(c = coupon, extra = '', seeded = []) {
  const dom = new JSDOM(html, { url: 'https://tele.port42.ai/' + extra + '#' + (c ? fragment(c) : 'not-a-coupon'),
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
  const storage = new Map(seeded);
  const store = { getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v) };
  const app = start({ win: dom.window, doc: dom.window.document, storage: store, connect });
  return { dom, doc: dom.window.document, calls, session, storage, app, connects: () => connects };
}

const settle = () => new Promise((r) => setTimeout(r, 20));


const join = async (p, name = 'Ada') => {
  p.doc.getElementById('name').value = name;
  p.doc.getElementById('gate').dispatchEvent(new p.dom.window.Event('submit', { cancelable: true }));
  await settle();
};

test('a link opens straight to the port, with one card to join it; nothing connects before the click', () => {
  const p = page();
  assert.equal(p.connects(), 0, 'the page connected before the person chose');
  assert.equal(p.dom.window.location.hash, '', 'the invite stayed in the address bar');
  assert.equal(p.doc.getElementById('port').hidden, false, 'the port is not the page');
  assert.equal(p.doc.getElementById('gate').hidden, false);
  assert.equal(p.doc.getElementById('title').textContent, 'chart');
  assert.equal(p.doc.getElementById('pill').textContent, "Gordon's", 'the pill does not say whose it is');
  assert.match(p.doc.getElementById('who').textContent, /Gordon shared 'chart' with you/);
  assert.match(p.doc.getElementById('what').textContent, /see and use/);
  assert.match(p.doc.getElementById('open-app').href, /^port42:\/\/invite#/);
  assert.match(p.doc.getElementById('get-app').href, /Port42\.dmg$/);
});

test('a link that is not an invite says so, and offers to take it pasted', () => {
  const p = page(null);
  assert.equal(p.doc.getElementById('paste').hidden, false);
  assert.match(p.doc.getElementById('paste-error').textContent, /not an invite/);
  assert.equal(p.connects(), 0);
});

test('the home page takes a pasted invite link, whole or as its fragment, and nothing else', () => {
  const dom = new JSDOM(html, { url: 'https://tele.port42.ai/' });
  const doc = dom.window.document;
  let connects = 0;
  start({ win: dom.window, doc, storage: null, connect: async () => { connects++; } });
  assert.equal(doc.getElementById('paste').hidden, false, 'the home page does not ask for a link');
  const submit = (text) => {
    doc.getElementById('paste-input').value = text;
    doc.getElementById('paste-form').dispatchEvent(new dom.window.Event('submit', { cancelable: true }));
  };
  submit('hello');
  assert.match(doc.getElementById('paste-error').textContent, /not an invite/);
  assert.equal(doc.getElementById('port').hidden, true);
  submit('  https://tele.port42.ai/#' + fragment(coupon) + '\n');
  assert.equal(doc.getElementById('port').hidden, false, 'a pasted link was not opened');
  assert.match(doc.getElementById('who').textContent, /Gordon shared 'chart'/);
  assert.equal(connects, 0, 'pasting a link connected before the person chose');
});

test('joining redeems the invite as the name given, then shows the port in a frame that holds no key', async () => {
  const p = page();
  await join(p);
  assert.equal(p.connects(), 1);
  assert.deepEqual(p.calls[0], { method: 'invite.redeem', args: { nonce: 'nonce-1', name: 'Ada' } });
  assert.equal(p.doc.getElementById('gate').hidden, true, 'the card stayed over the port');
  const frame = p.doc.getElementById('frame');
  assert.ok(!frame.getAttribute('sandbox').includes('allow-same-origin'), 'the frame can reach the page\'s storage');
  assert.match(frame.getAttribute('src'), /^frame\.html/, 'the port is not loaded in its own document');
  const sent = p.app.frameState.html;
  assert.match(sent, /<p>the port<\/p>/);
  assert.match(sent, /self: Object\.freeze/, 'the frame has no window.port42');
  const seed = p.storage.get('port42.guest.seed');
  assert.ok(seed && !sent.includes(seed), 'the guest\'s key is inside the frame');
  const run = p.doc.querySelector('#chat-list .run');
  assert.equal(run.querySelector('.who').textContent, 'Gordon');
  assert.equal(run.querySelector('.msg').textContent, 'hi');
  assert.equal(p.doc.getElementById('chat-toggle').hidden, false, 'no way to open the chat');
  assert.equal(p.doc.getElementById('chat-count').textContent, '1', 'the unread count is wrong');
});

test('a browser that joined this port before opens it at once, with its name remembered', async () => {
  const first = page();
  await join(first, 'Ada');
  const again = page(coupon, '', [...first.storage.entries()]);
  await settle();
  assert.equal(again.connects(), 1, 'a returning guest was asked again');
  assert.equal(again.calls[0].args.name, 'Ada');
  assert.equal(again.doc.getElementById('gate').hidden, true);
  const stranger = page();
  assert.equal(stranger.connects(), 0, 'a new browser joined without a click');
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
  await join(p);
  p.app.guest().retryMs = 60_000;
  p.session.onEnd(new Refusal('host_offline', 'gone'));
  assert.ok(p.doc.body.classList.contains('offline'));
  assert.equal(p.doc.getElementById('chat-input').disabled, true);
  assert.match(p.doc.getElementById('status').textContent, /Gordon's Mac is offline/);
  p.app.guest().stop();
});

test('an invite refused by the host is explained on the card, and the person can try again', async () => {
  const p = page();
  p.session.call = (m) => m === 'invite.redeem' ? Promise.reject(Object.assign(new Refusal('invite_invalid', 'used'), { reason: 'used' })) : Promise.resolve();
  await join(p);
  assert.match(p.doc.getElementById('join-error').textContent, /already been used/);
  assert.equal(p.doc.getElementById('join-button').disabled, false);
  assert.equal(p.doc.getElementById('gate').hidden, false);
});

test('a hidden section stays hidden whatever its own display rule says', () => {
  assert.match(html, /\[hidden\]\s*\{\s*display:\s*none\s*!important/, 'the page lets a section\'s own display beat hidden');
});

test('the chat drops down from the title bar, and opening it clears the unread count', async () => {
  const p = page();
  await join(p);
  const chat = p.doc.getElementById('chat');
  assert.ok(!chat.classList.contains('open'));
  p.doc.getElementById('chat-toggle').click();
  assert.ok(chat.classList.contains('open'));
  assert.equal(p.doc.getElementById('chat-count').hidden, true);
});
