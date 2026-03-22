#!/usr/bin/env node
/**
 * Port42 peer — connect to the gateway as a first-class peer.
 * Node 22+ required (built-in WebSocket + crypto).
 *
 * Usage:
 *   node peer.js                          # connect, list channels, watch messages
 *   node peer.js <channel-id>             # join a specific channel
 *   node peer.js <channel-id> "hi there"  # join and send a message
 */

const channelId = process.argv[2] ?? null;
const sendText  = process.argv[3] ?? null;

const PEER_ID   = 'peer-cli-' + Date.now();
const PEER_NAME = 'peer-cli';

// ─── state ────────────────────────────────────────────────────────────────────

const pending = new Map();   // callId → { resolve, label }
let joined    = false;

// ─── connect ──────────────────────────────────────────────────────────────────

console.log(`[peer] connecting as ${PEER_NAME}`);
const ws = new WebSocket('ws://127.0.0.1:4242/ws');

ws.addEventListener('error', e => {
  console.error(`[peer] connection failed: ${e.message}`);
  console.error('[peer] is Port42 running?');
  process.exit(1);
});

ws.addEventListener('close', () => {
  console.log('[peer] disconnected');
  process.exit(0);
});

// ─── helpers ─────────────────────────────────────────────────────────────────

function send(env) {
  ws.send(JSON.stringify(env));
}

function call(label, method, args = {}) {
  return new Promise(resolve => {
    const callId = crypto.randomUUID();
    pending.set(callId, { resolve, label });
    send({ type: 'call', call_id: callId, method, args });
  });
}

function fmt(payload) {
  if (!payload?.content) return '(empty)';
  try {
    return JSON.stringify(JSON.parse(payload.content), null, 2);
  } catch {
    return payload.content.trim();
  }
}

// ─── main flow ────────────────────────────────────────────────────────────────

async function onWelcome() {
  console.log('[peer] connected\n');

  // Always show who we are and what channels exist
  const user     = await call('user',     'user.get');
  const channels = await call('channels', 'channel.list');

  console.log('user:');
  console.log(' ', fmt(user));
  console.log('\nchannels:');
  console.log(' ', fmt(channels));

  if (!channelId) {
    console.log('\n[peer] pass a channel-id as argument to join and watch messages');
    ws.close();
    return;
  }

  // Join channel
  console.log(`\n[peer] joining ${channelId}...`);
  send({ type: 'join', channel_id: channelId });
}

async function onJoined() {
  if (joined) return;
  joined = true;

  const recent = await call('recent', 'messages.recent', { channel_id: channelId, count: 5 });
  console.log('\nlast 5 messages:');
  console.log(' ', fmt(recent));

  if (sendText) {
    const result = await call('send', 'messages.send', { channel_id: channelId, text: sendText });
    console.log('\nsent:', fmt(result));
    ws.close();
    return;
  }

  console.log('\n[peer] watching for messages (ctrl-c to quit)...\n');
}

// ─── message handler ──────────────────────────────────────────────────────────

ws.addEventListener('message', ({ data }) => {
  const env = JSON.parse(data);

  if (env.type === 'no_auth') {
    send({ type: 'identify', sender_id: PEER_ID, sender_name: PEER_NAME, is_host: false });
    return;
  }

  if (env.type === 'welcome') {
    onWelcome();
    return;
  }

  if (env.type === 'presence' && env.online_ids) {
    // First presence after join = we're in
    onJoined();
    return;
  }

  if (env.type === 'response') {
    const p = pending.get(env.call_id);
    if (p) {
      pending.delete(env.call_id);
      p.resolve(env.payload);
    }
    return;
  }

  if (env.type === 'message' || env.type === 'history') {
    const sender  = env.payload?.senderName ?? env.sender_id ?? '?';
    const content = env.payload?.content ?? '';
    const tag     = env.type === 'history' ? '[history]' : '[message]';
    console.log(`${tag} ${sender}: ${content}`);
    return;
  }

  if (env.type === 'error') {
    console.error(`[peer] error: ${env.error}`);
    return;
  }

  if (env.type === 'typing') return;   // ignore noise
  if (env.type === 'ack') return;
  if (env.type === 'delivered') return;

  // Anything else — show it
  console.log('[peer] recv:', env.type, JSON.stringify(env).slice(0, 120));
});
