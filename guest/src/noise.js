// Noise_IK_25519_ChaChaPoly_SHA256, the initiator's side, as the relay's Go peers speak it
// (gateway/relay/noise.go, flynn/noise). A guest knows the host's key from the invite, so IK:
// one round trip, both sides authenticated, the guest's identity sent encrypted.

import { ed25519, x25519, edwardsToMontgomeryPub } from '@noble/curves/ed25519';
import { chacha20poly1305 } from '@noble/ciphers/chacha';
import { sha256, sha512 } from '@noble/hashes/sha2';
import { hmac } from '@noble/hashes/hmac';

const PROTOCOL = 'Noise_IK_25519_ChaChaPoly_SHA256';   // exactly 32 bytes, so it is h as is
export const PROLOGUE = 'port42-noise-v1';
export const MAX_NOISE_MESSAGE = 65535;
const TAG = 16;

const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/// This instance's X25519 key for Noise, from its Ed25519 seed, as NoiseKey in noise.go: the first
/// half of SHA-512 of the seed (X25519 clamps it when used).
export function noiseKeyFromSeed(seed) {
  const priv = sha512(seed).slice(0, 32);
  return { priv, pub: x25519.getPublicKey(priv) };
}

/// A host's X25519 static key, from its Ed25519 public key (the peer id), as MontgomeryPublic.
export function montgomeryFromEd25519(pub) { return edwardsToMontgomeryPub(pub); }

function hkdf(ck, ikm, n) {
  const temp = hmac(sha256, ck, ikm);
  const o1 = hmac(sha256, temp, Uint8Array.of(1));
  const o2 = hmac(sha256, temp, concat(o1, Uint8Array.of(2)));
  return n === 2 ? [o1, o2] : [o1, o2, hmac(sha256, temp, concat(o2, Uint8Array.of(3)))];
}

function nonce(n) {
  const b = new Uint8Array(12);
  new DataView(b.buffer).setBigUint64(4, BigInt(n), true);
  return b;
}

/// One direction of a session: ChaCha20-Poly1305 with Noise's counter nonce.
export class CipherState {
  constructor(k) { this.k = k; this.n = 0; }
  encrypt(ad, plain) { return chacha20poly1305(this.k, nonce(this.n++), ad).encrypt(plain); }
  decrypt(ad, sealed) { return chacha20poly1305(this.k, nonce(this.n++), ad).decrypt(sealed); }
}

class SymmetricState {
  constructor() {
    this.h = new TextEncoder().encode(PROTOCOL);
    this.ck = this.h;
    this.cipher = null;
  }
  mixHash(data) { this.h = sha256(concat(this.h, data)); }
  mixKey(ikm) {
    const [ck, k] = hkdf(this.ck, ikm, 2);
    this.ck = ck;
    this.cipher = new CipherState(k);
  }
  encryptAndHash(p) {
    const c = this.cipher ? this.cipher.encrypt(this.h, p) : p;
    this.mixHash(c);
    return c;
  }
  decryptAndHash(c) {
    const p = this.cipher ? this.cipher.decrypt(this.h, c) : c;
    this.mixHash(c);
    return p;
  }
  split() {
    const [k1, k2] = hkdf(this.ck, new Uint8Array(0), 2);
    return [new CipherState(k1), new CipherState(k2)];
  }
}

/// The initiator of IK. `seed` is this guest's Ed25519 seed; `hostEd25519` the host's public key.
/// writeFirst() gives the first message, carrying `payload` (the guest's Ed25519 public key, which
/// the host checks against the Noise static); readSecond() takes the host's answer and returns the
/// two cipher states, [send, recv].
export class Initiator {
  constructor(seed, hostEd25519, { ephemeral, prologue = PROLOGUE } = {}) {
    this.s = noiseKeyFromSeed(seed);
    this.rs = montgomeryFromEd25519(hostEd25519);
    const ePriv = ephemeral ?? x25519.utils.randomPrivateKey();
    this.e = { priv: ePriv, pub: x25519.getPublicKey(ePriv) };
    this.ss = new SymmetricState();
    this.ss.mixHash(new TextEncoder().encode(prologue));
    this.ss.mixHash(this.rs);                       // <- s, known before the handshake
  }

  writeFirst(payload) {
    const ss = this.ss;
    ss.mixHash(this.e.pub);                                            // e
    ss.mixKey(x25519.getSharedSecret(this.e.priv, this.rs));          // es
    const encS = ss.encryptAndHash(this.s.pub);                        // s
    ss.mixKey(x25519.getSharedSecret(this.s.priv, this.rs));          // ss
    const encP = ss.encryptAndHash(payload);
    return concat(this.e.pub, encS, encP);
  }

  readSecond(msg) {
    const ss = this.ss;
    if (msg.length < 32 + TAG) throw new Error('the host sent a short handshake');
    const re = msg.slice(0, 32);
    ss.mixHash(re);                                                    // e
    ss.mixKey(x25519.getSharedSecret(this.e.priv, re));               // ee
    ss.mixKey(x25519.getSharedSecret(this.s.priv, re));               // se
    ss.decryptAndHash(msg.slice(32));                                  // empty payload, authenticated
    return ss.split();
  }
}

export { ed25519 };
