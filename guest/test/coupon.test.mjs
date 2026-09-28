// A relay named in an invite is reached over wss:// (REL-03); ws:// only to this machine, for a relay
// run locally. A plaintext relay exposed the relay hello and who talks to whom.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decodeCoupon, secureRelay } from '../src/coupon.js';

const coupon = (relays) => Buffer.from(JSON.stringify({ v: 1, host: 'a'.repeat(52), relays, port: 'p', nonce: 'n', rights: ['see'] }))
  .toString('base64url');

test('an invite naming a plaintext relay is refused', () => {
  assert.ok(decodeCoupon(coupon(['wss://relay1.port42.ai/v1'])), 'a wss relay was refused');
  assert.equal(decodeCoupon(coupon(['ws://relay.example/v1'])), null, 'a plaintext relay was accepted');
  assert.equal(decodeCoupon(coupon(['wss://relay1.port42.ai/v1', 'ws://evil.example/v1'])), null);
  assert.ok(decodeCoupon(coupon(['ws://127.0.0.1:8080/v1'])), 'a local relay was refused');
});

test('only loopback may use ws://', () => {
  for (const ok of ['wss://x/v1', 'ws://localhost:1/v1', 'ws://127.0.0.1/v1', 'ws://[::1]:9/v1']) assert.ok(secureRelay(ok), ok);
  for (const bad of ['ws://example.com/v1', 'ws://localhost.evil.com/v1', 'ws://127.0.0.1.evil.com/v1', 'http://x', 42]) {
    assert.equal(secureRelay(bad), false, String(bad));
  }
});
