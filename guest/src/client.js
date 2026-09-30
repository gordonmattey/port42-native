// A guest's connection to a Port42 on another machine, through a relay (gateway/relay/client.go,
// dialVia): connect, answer the relay's challenge with a signed hello, ask for the host by its peer
// id, run the Noise IK handshake, then carry the door's envelopes (call, response, stream, error),
// each split into chunks with a one-byte header (transport/chunk.go). The relay sees only ciphertext.

import { Initiator, MAX_NOISE_MESSAGE, PROLOGUE, PROLOGUE_V2, v2Binding } from './noise.js';
import { parsePeerId } from './peer.js';

const MAX_PLAIN_FRAME = MAX_NOISE_MESSAGE - 16;
const MAX_MESSAGE = 8 << 20;
const MORE = 1, LAST = 0;
const enc = new TextEncoder(), dec = new TextDecoder();

/// A refusal with a code a person can be told about: host_offline, rate_limited, limit, refused,
/// bad_hello, or the host's own (not_granted, invite_invalid, stale_write…).
export class Refusal extends Error {
  constructor(code, message, details = {}) {
    super(message || code);
    this.code = code;
    Object.assign(this, details);
  }
}

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const concatBytes = (a, b) => { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; };

export function helloText(relay, nonce, role) {
  return enc.encode(`port42-relay-v1|${relay}|${nonce}|${role}`);
}

/// Frames of one WebSocket as an async queue: text frames are control messages, binary ones data.
function frames(ws) {
  const queue = [], waiting = [];
  let closed = null;
  const push = (item) => { const w = waiting.shift(); if (w) w.resolve(item); else queue.push(item); };
  ws.addEventListener('message', (ev) => {
    if (typeof ev.data === 'string') push({ text: JSON.parse(ev.data) });
    else push({ bytes: new Uint8Array(ev.data) });
  });
  const end = (reason) => {
    if (closed) return;
    closed = reason;
    for (const w of waiting.splice(0)) w.reject(reason);
  };
  ws.addEventListener('close', () => end(new Refusal('host_offline', 'the connection to the relay closed')));
  ws.addEventListener('error', () => end(new Refusal('host_offline', 'the relay could not be reached')));
  return {
    next() {
      if (queue.length) return Promise.resolve(queue.shift());
      if (closed) return Promise.reject(closed);
      return new Promise((resolve, reject) => waiting.push({ resolve, reject }));
    },
    get closed() { return closed; },
  };
}

async function control(q, want) {
  const m = await q.next();
  if (!m.text) throw new Refusal('bad_hello', 'the relay sent data where it should have spoken');
  if (m.text.t === 'error') throw new Refusal(m.text.code, m.text.message);
  if (m.text.t !== want) throw new Refusal('bad_hello', `expected ${want} from the relay, got ${m.text.t}`);
  return m.text;
}

/// Open a session to `host` (a peer id) through the first of `relays` that can reach it, as
/// `identity` (from peer.js). Resolves to a Session, or rejects with the last Refusal.
export async function connect({ relays, host, identity, WebSocketImpl = globalThis.WebSocket, prologue }) {
  let last = new Refusal('host_offline', 'no relays');
  for (const relay of relays) {
    try { return await connectVia(relay, host, identity, WebSocketImpl, prologue); }
    catch (e) { last = e instanceof Refusal ? e : new Refusal('host_offline', String(e?.message ?? e)); }
  }
  throw last;
}

/// The WebSocket subprotocol a relay connection speaks, registered for Port42 with IANA (#220).
export const SUBPROTOCOL = 'port42';

/// Open a socket to a relay, offering the "port42" subprotocol. A browser fails the handshake when it
/// offers a subprotocol the server does not echo, so a relay that predates it (or someone's own) is
/// tried again offering none. Resolves to [socket, frames] once open.
export async function openRelaySocket(WS, relayURL) {
  const attempt = (protocols) => {
    const ws = protocols ? new WS(relayURL, protocols) : new WS(relayURL);
    ws.binaryType = 'arraybuffer';
    const q = frames(ws);
    return new Promise((resolve, reject) => {
      ws.addEventListener('open', () => resolve([ws, q]), { once: true });
      ws.addEventListener('error', () => reject(new Refusal('host_offline', 'the relay could not be reached')), { once: true });
    });
  };
  try { return await attempt([SUBPROTOCOL]); }
  catch { return attempt(null); }
}

async function connectVia(relayURL, host, identity, WS, prologue) {
  const hostKey = parsePeerId(host);
  const [ws, q] = await openRelaySocket(WS, relayURL);
  try {
    const ch = await control(q, 'challenge');
    if (ch.relay !== new URL(relayURL).host) throw new Refusal('bad_hello', `the relay calls itself ${ch.relay}`);
    ws.send(JSON.stringify({ t: 'hello', role: 'guest', key: identity.id,
                             sig: b64(await identity.sign(helloText(ch.relay, ch.nonce, 'guest'))) }));
    await control(q, 'ok');
    ws.send(JSON.stringify({ t: 'open', to: host }));
    await control(q, 'opened');

    // v2 (GST-02): keys the page cannot read. The Ed25519 key signs that the X25519 key speaks for
    // it, to this host, in this handshake. v1: the X25519 key is derived from the seed, so the public
    // Ed25519 key alone names it.
    const v2 = identity.version === 2;
    const hs = new Initiator(identity.noise ?? identity.seed, hostKey, { prologue: prologue ?? (v2 ? PROLOGUE_V2 : PROLOGUE) });
    const payload = v2
      ? concatBytes(identity.pub, await identity.sign(v2Binding(host, hs.e.pub, identity.noise.pub)))
      : identity.pub;
    ws.send(await hs.writeFirst(payload));
    // A host that cannot read our handshake (not the key the invite named) ends the session.
    const m = await q.next().catch(() => { throw new Refusal('refused', 'the host refused the session'); });
    if (!m.bytes) {
      if (m.text?.t === 'error') throw new Refusal(m.text.code, m.text.message);
      throw new Refusal('refused', 'the host did not answer the handshake');
    }
    let send, recv;
    try { [send, recv] = await hs.readSecond(m.bytes); }
    catch { throw new Refusal('refused', 'the host did not prove its key'); }
    return new Session(ws, q, send, recv);
  } catch (e) {
    try { ws.close(); } catch {}
    throw e;
  }
}

/// An open session: calls by id, streamed events, and an end when the connection goes.
export class Session {
  constructor(ws, q, send, recv) {
    this.ws = ws; this.q = q; this.sendCipher = send; this.recvCipher = recv;
    this.pending = new Map();
    this.nextId = 0;
    this.buf = [];
    this.bufLen = 0;
    this.onEnd = null;
    this.ended = null;
    this.pump();
  }

  sendMessage(obj) {
    const msg = enc.encode(JSON.stringify(obj));
    const body = MAX_PLAIN_FRAME - 1;
    let at = 0;
    do {
      const n = Math.min(body, msg.length - at);
      const frame = new Uint8Array(n + 1);
      frame[0] = at + n < msg.length ? MORE : LAST;
      frame.set(msg.subarray(at, at + n), 1);
      this.ws.send(this.sendCipher.encrypt(new Uint8Array(0), frame));
      at += n;
    } while (at < msg.length);
  }

  /// Call a method on the host's port. Resolves with the result; rejects with a Refusal carrying
  /// the host's code and every other field it sent (so `current` survives for a retry).
  call(method, args = {}, { onStream } = {}) {
    if (this.ended) return Promise.reject(this.ended);
    const id = 'g-' + (++this.nextId);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, onStream });
      this.sendMessage({ type: 'call', method, args, call_id: id });
    });
  }

  close() { try { this.ws.close(); } catch {} }

  async pump() {
    try {
      for (;;) {
        const m = await this.q.next();
        if (!m.bytes) continue;
        const frame = this.recvCipher.decrypt(new Uint8Array(0), m.bytes);
        if (this.bufLen + frame.length - 1 > MAX_MESSAGE) throw new Refusal('too_large', 'a message was too large');
        this.buf.push(frame.subarray(1)); this.bufLen += frame.length - 1;
        if (frame[0] === MORE) continue;
        const whole = new Uint8Array(this.bufLen);
        let at = 0;
        for (const p of this.buf) { whole.set(p, at); at += p.length; }
        this.buf = []; this.bufLen = 0;
        this.deliver(JSON.parse(dec.decode(whole)));
      }
    } catch (e) {
      this.end(e instanceof Refusal ? e : new Refusal('host_offline', 'the session ended'));
    }
  }

  deliver(env) {
    const p = this.pending.get(env.call_id);
    if (!p) return;
    const content = () => {
      const c = env.payload?.content;
      if (typeof c !== 'string') return c ?? null;
      try { return JSON.parse(c); } catch { return c; }
    };
    if (env.type === 'stream') { p.onStream?.(content()); return; }
    this.pending.delete(env.call_id);
    if (env.type === 'error') { p.reject(new Refusal(env.code || 'refused', env.error)); return; }
    const out = content();
    if (out && typeof out === 'object' && !Array.isArray(out) && typeof out.code === 'string' && 'error' in out) {
      const { code, error, ...details } = out;
      p.reject(new Refusal(code, error, details));
    } else {
      p.resolve(out);
    }
  }

  end(reason) {
    if (this.ended) return;
    this.ended = reason;
    for (const p of this.pending.values()) p.reject(reason);
    this.pending.clear();
    this.onEnd?.(reason);
  }
}
