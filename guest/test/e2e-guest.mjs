// Run by gateway/guest_e2e_test.go: the browser guest's runtime, in Node, against a real relay and a
// real host gateway. Prints one JSON line per step; the Go test checks them and plays the host's app.
import { connect, Refusal } from '../src/client.js';
import { identity, newSeed } from '../src/peer.js';
import { loadIdentity } from '../src/keys.js';

const [relay, host, mode] = process.argv.slice(2);
// "v2": keys the page cannot read (GST-02), as a browser whose host advertises v2 holds them.
const memory = () => { const m = new Map(); return { get: async (k) => m.get(k), set: async (k, v) => { m.set(k, v); } }; };
const me = mode === 'v2'
  ? await loadIdentity({ storage: null, store: memory(), coupon: { noise: [1, 2] } })
  : identity(newSeed());
const say = (o) => process.stdout.write(JSON.stringify(o) + '\n');
say({ step: 'me', id: me.id, version: me.version ?? 1 });

try {
  const s = await connect({ relays: [relay], host, identity: me,
                            prologue: mode === 'wrong-prologue' ? 'port42-noise-v0' : undefined });
  if (mode === 'wrong-host') { say({ step: 'connected-to-wrong-host' }); process.exit(0); }
  say({ step: 'redeem', out: await s.call('invite.redeem', { nonce: 'n-1', name: 'a browser' }) });
  say({ step: 'getHtml', out: await s.call('port.getHtml', { id: 'P' }) });
  let token = 't:1';
  try { await s.call('port.push', { id: 'P', data: { n: 1 }, token }); say({ step: 'push', out: 'no refusal' }); }
  catch (e) {
    say({ step: 'refused', code: e.code, current: e.current });
    token = e.current;
    say({ step: 'push', out: await s.call('port.push', { id: 'P', data: { n: 1 }, token }) });
  }
  const event = await new Promise((resolve) => { s.call('port.subscribe', { id: 'P' }, { onStream: resolve }); });
  say({ step: 'event', event });
  const big = 'x'.repeat(200_000);
  say({ step: 'big', out: (await s.call('port.getHtml', { id: 'P', echo: big })).length });
  s.close();
  process.exit(0);
} catch (e) {
  say({ step: 'failed', code: e instanceof Refusal ? e.code : 'error', message: String(e?.message ?? e) });
  process.exit(0);
}
