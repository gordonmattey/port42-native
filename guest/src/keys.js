// A guest's keys (GST-02, docs/design-gst02-guest-keys.md).
//
// Where the browser can make them, a guest holds two WebCrypto keys the page cannot read: an Ed25519
// identity key (its public key is the guest's peer id) and a separate X25519 key for the Noise
// handshake. They live in IndexedDB as CryptoKey objects, never as bytes a script could copy. The
// handshake that uses them is v2, which a host accepts only from the version that advertises it in
// its invite ("noise": [1, 2]).
//
// Where it cannot, or for a host that speaks v1 only, the guest keeps the older identity: one Ed25519
// seed in localStorage, from which the Noise key is derived (v1).

import { Refusal } from './client.js';
import { identity as seedIdentity, newSeed, peerId } from './peer.js';
import { noiseKeyFromSeed } from './noise.js';
import { ed25519, x25519 } from '@noble/curves/ed25519';

export const SEED_KEY = 'port42.guest.seed';
const SEALED = 'guest-keys';
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
const unhex = (s) => Uint8Array.from(s.match(/../g).map((h) => parseInt(h, 16)));

// An Ed25519 private key in PKCS#8: this fixed prefix, then the 32-byte seed (RFC 8410).
const PKCS8_ED25519 = unhex('302e020100300506032b657004220420');

/// Does this invite's host accept a guest on the new keys? A coupon without `noise` is from a host
/// that speaks v1 only.
export function hostAcceptsV2(coupon) {
  return Array.isArray(coupon?.noise) && coupon.noise.includes(2);
}

/// Can this browser make both keys without letting them be read?
export async function canSealKeys(subtle) {
  if (!subtle) return false;
  try {
    await subtle.generateKey({ name: 'Ed25519' }, false, ['sign']);
    await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
    return true;
  } catch { return false; }
}

/// The identity to join with, for this invite. `store` keeps the sealed keys (IndexedDB in a
/// browser); `storage` is localStorage, where a seed from before may be.
///
/// A guest that has moved to the new keys and meets a host that speaks v1 only cannot join it: the
/// seed that v1 needs is gone. It is told to ask for an updated link.
export async function loadIdentity({ storage, store, subtle = globalThis.crypto?.subtle, coupon }) {
  const sealed = store ? await store.get(SEALED).catch(() => undefined) : undefined;
  if (hostAcceptsV2(coupon) && store && (sealed || await canSealKeys(subtle))) {
    return sealedIdentity(sealed ?? await sealTheKeys({ storage, store, subtle }), subtle);
  }
  if (sealed) {
    throw new Refusal('host_outdated', 'this invite is from a version of Port42 that cannot take this guest');
  }
  return v1Identity(storage);
}

/// The older identity: a seed in localStorage, made on first use.
export function v1Identity(storage) {
  let seedHex = null;
  try { seedHex = storage?.getItem(SEED_KEY); } catch {}
  const seed = seedHex && /^[0-9a-f]{64}$/.test(seedHex) ? unhex(seedHex) : newSeed();
  if (!seedHex) { try { storage?.setItem(SEED_KEY, hex(seed)); } catch {} }
  const me = seedIdentity(seed);
  const s = noiseKeyFromSeed(seed);
  return {
    version: 1, pub: me.pub, id: me.id,
    sign: async (msg) => me.sign(msg),
    noise: { pub: s.pub, dh: async (peer) => x25519.getSharedSecret(s.priv, peer) },
  };
}

/// Make the sealed keys: the Ed25519 key from the seed this guest already has, so its peer id and
/// every host's grants are kept, or a new one; then a new X25519 key. Store them, then delete the seed.
async function sealTheKeys({ storage, store, subtle }) {
  let seedHex = null;
  try { seedHex = storage?.getItem(SEED_KEY); } catch {}
  let edPriv, edPub;
  if (seedHex && /^[0-9a-f]{64}$/.test(seedHex)) {
    const seed = unhex(seedHex);
    const pkcs8 = new Uint8Array(PKCS8_ED25519.length + 32);
    pkcs8.set(PKCS8_ED25519); pkcs8.set(seed, PKCS8_ED25519.length);
    edPriv = await subtle.importKey('pkcs8', pkcs8, { name: 'Ed25519' }, false, ['sign']);
    edPub = ed25519.getPublicKey(seed);
  } else {
    const pair = await subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']);
    edPriv = pair.privateKey;
    edPub = new Uint8Array(await subtle.exportKey('raw', pair.publicKey));
  }
  const x = await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
  const keys = { edPriv, edPub, xPriv: x.privateKey, xPub: new Uint8Array(await subtle.exportKey('raw', x.publicKey)) };
  await store.set(SEALED, keys);
  // Only once the keys are safely stored: the seed leaves localStorage for good (Gordon, 2026-09-29).
  try { storage?.removeItem(SEED_KEY); } catch {}
  return keys;
}

function sealedIdentity(keys, subtle) {
  return {
    version: 2, pub: keys.edPub, id: peerId(keys.edPub),
    sign: async (msg) => new Uint8Array(await subtle.sign({ name: 'Ed25519' }, keys.edPriv, msg)),
    noise: {
      pub: keys.xPub,
      dh: async (peer) => {
        const pub = await subtle.importKey('raw', peer, { name: 'X25519' }, false, []);
        return new Uint8Array(await subtle.deriveBits({ name: 'X25519', public: pub }, keys.xPriv, 256));
      },
    },
  };
}

/// The sealed keys' store in a browser: one IndexedDB object store. CryptoKeys are kept as they are,
/// and a non-extractable key stays non-extractable when read back.
export function indexedDBStore(idb = globalThis.indexedDB) {
  if (!idb) return null;
  const db = () => new Promise((resolve, reject) => {
    const req = idb.open('port42-guest', 1);
    req.onupgradeneeded = () => req.result.createObjectStore('keys');
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  const tx = async (mode, fn) => {
    const d = await db();
    return new Promise((resolve, reject) => {
      const t = d.transaction('keys', mode);
      const req = fn(t.objectStore('keys'));
      t.oncomplete = () => { d.close(); resolve(req.result); };
      t.onerror = () => { d.close(); reject(t.error); };
    });
  };
  return {
    get: (k) => tx('readonly', (s) => s.get(k)),
    set: (k, v) => tx('readwrite', (s) => s.put(v, k)),
  };
}
