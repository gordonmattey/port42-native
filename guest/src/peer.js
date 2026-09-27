// A Port42 instance's id and key, as transport/peerid.go: the id is the Ed25519 public key in
// lowercase base32 without padding, 52 characters.

import { ed25519 } from '@noble/curves/ed25519';

const ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';

export function peerId(pub) {
  let bits = 0, value = 0, out = '';
  for (const byte of pub) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function parsePeerId(id) {
  if (typeof id !== 'string' || id.length !== 52) throw new Error('not a peer id');
  let bits = 0, value = 0;
  const out = [];
  for (const ch of id) {
    const v = ALPHABET.indexOf(ch);
    if (v < 0) throw new Error('not a peer id');
    value = (value << 5) | v; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  if (out.length !== 32) throw new Error('not a peer id');
  return Uint8Array.from(out);
}

/// A guest identity: an Ed25519 seed, its public key and its peer id.
export function identity(seed) {
  const pub = ed25519.getPublicKey(seed);
  return { seed, pub, id: peerId(pub), sign: (msg) => ed25519.sign(msg, seed) };
}

export function newSeed() { return ed25519.utils.randomPrivateKey(); }
