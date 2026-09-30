// #220: the guest page offers the "port42" WebSocket subprotocol, and falls back to none for a relay
// that predates it (a browser fails a handshake whose offered subprotocol is not echoed).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openRelaySocket, SUBPROTOCOL } from '../src/client.js';

// A stand-in for the browser's WebSocket: `accepts(protocols)` decides whether the handshake opens.
function fakeWS(accepts) {
  const made = [];
  class WS {
    constructor(url, protocols) {
      this.url = url; this.protocols = protocols; this.listeners = {};
      made.push(this);
      queueMicrotask(() => this.fire(accepts(protocols) ? 'open' : 'error'));
    }
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
    fire(type) { for (const fn of this.listeners[type] ?? []) fn({}); }
    send() {}
    close() {}
  }
  return { WS, made };
}

test('the guest offers port42, and a relay that echoes it is used as is', async () => {
  const { WS, made } = fakeWS(() => true);
  const [ws] = await openRelaySocket(WS, 'wss://relay1.port42.ai/v1');
  assert.equal(SUBPROTOCOL, 'port42');
  assert.deepEqual(ws.protocols, ['port42']);
  assert.equal(made.length, 1, 'it connected twice to a relay that accepted the first time');
});

test('a relay that does not echo port42 is tried again offering none', async () => {
  const { WS, made } = fakeWS((protocols) => !protocols);   // an older relay: the offer fails the handshake
  const [ws] = await openRelaySocket(WS, 'wss://old.example/v1');
  assert.equal(made.length, 2);
  assert.equal(ws.protocols, undefined, 'the fallback still offered a subprotocol');
});

test('a relay that cannot be reached at all is refused after the fallback, not retried for ever', async () => {
  const { WS, made } = fakeWS(() => false);
  await assert.rejects(openRelaySocket(WS, 'wss://down.example/v1'), /could not be reached/);
  assert.equal(made.length, 2);
});
