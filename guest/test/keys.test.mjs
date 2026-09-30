// GST-02: a guest's keys the page cannot read (docs/design-gst02-guest-keys.md).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ed25519 } from '@noble/curves/ed25519';
import { loadIdentity, hostAcceptsV2, SEED_KEY } from '../src/keys.js';
import { explain } from '../src/guest.js';
import { peerId } from '../src/peer.js';
import { v2Binding } from '../src/noise.js';
import { decodeCoupon } from '../src/coupon.js';

const v2 = { noise: [1, 2] };
const v1only = {};
const memoryStore = () => { const m = new Map(); return { m, get: async (k) => m.get(k), set: async (k, v) => { m.set(k, v); } }; };
const memoryStorage = (init = {}) => {
  const m = new Map(Object.entries(init));
  return { m, getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: (k) => m.delete(k) };
};
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

test('a guest whose host accepts v2 holds keys the page cannot read, kept across a reload', async () => {
  const store = memoryStore(), storage = memoryStorage();
  const me = await loadIdentity({ storage, store, coupon: v2 });
  assert.equal(me.version, 2);
  const { edPriv, xPriv } = store.m.get('guest-keys');
  await assert.rejects(crypto.subtle.exportKey('pkcs8', edPriv), 'the identity key can be read out');
  await assert.rejects(crypto.subtle.exportKey('pkcs8', xPriv), 'the Noise key can be read out');
  assert.equal(storage.m.get(SEED_KEY), undefined, 'a seed was written for a guest on the new keys');
  const again = await loadIdentity({ storage, store, coupon: v2 });
  assert.equal(again.id, me.id, 'a reload is a different guest');
});

test('a guest with a seed keeps its peer id on the new keys, and the seed leaves localStorage', async () => {
  const seed = ed25519.utils.randomPrivateKey();
  const storage = memoryStorage({ [SEED_KEY]: hex(seed) }), store = memoryStore();
  const me = await loadIdentity({ storage, store, coupon: v2 });
  assert.equal(me.version, 2);
  assert.equal(me.id, peerId(ed25519.getPublicKey(seed)), 'moving to the new keys changed who the guest is');
  assert.equal(storage.m.get(SEED_KEY), undefined, 'the seed is still in localStorage');
  // A standard RFC 8032 signature: what the relay's ed25519.Verify and the host accept.
  const msg = new TextEncoder().encode('port42-relay-v1|relay|nonce|guest');
  assert.ok(ed25519.verify(await me.sign(msg), msg, me.pub), 'a WebCrypto signature does not verify as Ed25519');
});

test('a browser that cannot make the keys keeps the seed and v1, and still joins', async () => {
  const subtle = { generateKey: async () => { throw new Error('NotSupportedError'); } };
  const storage = memoryStorage(), store = memoryStore();
  const me = await loadIdentity({ storage, store, subtle, coupon: v2 });
  assert.equal(me.version, 1);
  assert.match(storage.m.get(SEED_KEY) ?? '', /^[0-9a-f]{64}$/, 'the fallback made no seed');
  assert.equal(store.m.size, 0);
});

test('a guest on the new keys meeting a v1-only invite is told to ask for an updated link', async () => {
  const store = memoryStore(), storage = memoryStorage();
  await loadIdentity({ storage, store, coupon: v2 });
  await assert.rejects(loadIdentity({ storage, store, coupon: v1only }), (e) => e.code === 'host_outdated');
  assert.equal(explain('host_outdated', 'Ada'), 'Ada needs to update Port42 and send you a new link.');
});

test('a guest that never moved keeps v1 for a v1-only invite', async () => {
  const storage = memoryStorage(), store = memoryStore();
  const me = await loadIdentity({ storage, store, coupon: v1only });
  assert.equal(me.version, 1);
  assert.ok(storage.m.get(SEED_KEY));
});

test('the invite says which handshakes its host accepts', () => {
  assert.equal(hostAcceptsV2({ noise: [1, 2] }), true);
  assert.equal(hostAcceptsV2({ noise: [1] }), false);
  assert.equal(hostAcceptsV2({}), false, 'a coupon from before means v1 only');
  const json = { v: 1, host: 'a'.repeat(52), relays: ['wss://r/v1'], port: 'P', nonce: 'n', rights: ['see'], noise: [1, 2] };
  const frag = btoa(JSON.stringify(json)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  assert.deepEqual(decodeCoupon('#' + frag)?.noise, [1, 2], 'the coupon lost its noise field');
});

test('the v2 binding is the bytes the host checks (noise.go, V2Binding)', () => {
  const b = v2Binding('HOST', new Uint8Array(32).fill(1), new Uint8Array(32).fill(2));
  const prefix = 'port42-noise-v2 static|HOST';
  assert.equal(new TextDecoder().decode(b.slice(0, prefix.length)), prefix);
  assert.equal(b.length, prefix.length + 64);
});

// Found on Dev5 (2026-09-29): an app that embeds WebKit, Port42's own browser among them, keeps a
// CryptoKey in IndexedDB only with a master key of its own; without one the write succeeds and the read
// returns nothing. The guest then made new keys on every reload and lost its identity, with the seed
// already gone. It must read the keys back before it lets the seed go, and stay on the seed if not.
test('where stored keys do not read back, the guest keeps its seed and its identity', async () => {
  const forgetful = { get: async () => undefined, set: async () => {} };
  const storage = memoryStorage();
  const first = await loadIdentity({ storage, store: forgetful, coupon: v2 });
  assert.equal(first.version, 1, 'it stays on the seed');
  assert.ok(storage.getItem(SEED_KEY), 'the seed is still there');
  const again = await loadIdentity({ storage, store: forgetful, coupon: v2 });   // a reload
  assert.equal(again.id, first.id, 'the same guest after a reload');
});
