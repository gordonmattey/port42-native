// Noise_IK_25519_ChaChaPoly_SHA256, the initiator's side, as the relay's Go peers speak it
// (gateway/relay/noise.go, flynn/noise). A guest knows the host's key from the invite, so IK:
// one round trip, both sides authenticated, the guest's identity sent encrypted.

import { ed25519, x25519, edwardsToMontgomeryPub } from '@noble/curves/ed25519';
import { chacha20poly1305 } from '@noble/ciphers/chacha';
import { sha256, sha512 } from '@noble/hashes/sha2';
import { hmac } from '@noble/hashes/hmac';

const PROTOCOL = 'Noise_IK_25519_ChaChaPoly_SHA256';   // exactly 32 bytes, so it is h as is
export const PROLOGUE = 'port42-noise-v1';
/// A guest whose keys the page cannot read (GST-02): a separate X25519 key, bound to its Ed25519
/// identity by a signature over v2Binding.
export const PROLOGUE_V2 = 'port42-noise-v2';
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

/// What a v2 guest signs with its Ed25519 key: that its X25519 static key speaks for it, to this host
/// (its peer id), in this handshake (its ephemeral key). The same bytes as V2Binding in noise.go.
export function v2Binding(hostId, ephemeralPub, staticPub) {
  return concat(new TextEncoder().encode('port42-noise-v2 static|' + hostId), ephemeralPub, staticPub);
}

/// A static key as the handshake uses it: its public key, and a DH with a peer's public key. A v1
/// guest's is derived from its seed; a v2 guest's is a WebCrypto key the page cannot read, so the DH
/// is asynchronous.
export function staticFromSeed(seed) {
  const s = noiseKeyFromSeed(seed);
  return { pub: s.pub, dh: async (peer) => x25519.getSharedSecret(s.priv, peer) };
}

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

/// The initiator of IK. `stat` is the guest's static key ({ pub, dh }, or a v1 seed); `hostEd25519`
/// the host's public key. `e.pub` is known from construction, so a v2 guest can sign it into its
/// payload. writeFirst() gives the first message, carrying `payload` (v1: the guest's Ed25519 public
/// key, which the host checks against the Noise static; v2: that key and its signature over
/// v2Binding); readSecond() takes the host's answer and returns the two cipher states, [send, recv].
export class Initiator {
  constructor(stat, hostEd25519, { ephemeral, prologue = PROLOGUE } = {}) {
    this.s = stat instanceof Uint8Array ? staticFromSeed(stat) : stat;
    this.rs = montgomeryFromEd25519(hostEd25519);
    const ePriv = ephemeral ?? x25519.utils.randomPrivateKey();
    this.e = { priv: ePriv, pub: x25519.getPublicKey(ePriv) };
    this.ss = new SymmetricState();
    this.ss.mixHash(new TextEncoder().encode(prologue));
    this.ss.mixHash(this.rs);                       // <- s, known before the handshake
  }

  async writeFirst(payload) {
    const ss = this.ss;
    ss.mixHash(this.e.pub);                                            // e
    ss.mixKey(x25519.getSharedSecret(this.e.priv, this.rs));          // es
    const encS = ss.encryptAndHash(this.s.pub);                        // s
    ss.mixKey(await this.s.dh(this.rs));                               // ss
    const encP = ss.encryptAndHash(payload);
    return concat(this.e.pub, encS, encP);
  }

  async readSecond(msg) {
    const ss = this.ss;
    if (msg.length < 32 + TAG) throw new Error('the host sent a short handshake');
    const re = msg.slice(0, 32);
    ss.mixHash(re);                                                    // e
    ss.mixKey(x25519.getSharedSecret(this.e.priv, re));               // ee
    ss.mixKey(await this.s.dh(re));                                    // se
    ss.decryptAndHash(msg.slice(32));                                  // empty payload, authenticated
    return ss.split();
  }
}

export { ed25519 };
