#!/usr/bin/env node
/**
 * Port42 RPC test suite
 * Node 22+ required (uses built-in WebSocket + crypto)
 *
 * BEFORE YOU RUN:
 *   1. Port42 app must be open
 *   2. Run: node test-rpc.js
 *
 * WHAT HAPPENS:
 *   Terminal: shows each test step
 *   Port42 app: shows a permission dialog for terminal + filesystem access
 *   Terminal: shows pass/fail for each test
 */

const WS_URL = 'ws://127.0.0.1:4242/ws';

const TESTS = [
  {
    name: 'clipboard.read',
    method: 'clipboard.read',
    args: {},
    check: r => typeof r === 'string' || typeof r?.content === 'string'
  },
  {
    name: 'terminal.exec — echo',
    method: 'terminal.exec',
    args: { command: 'echo "port42 rpc works"' },
    check: r => r?.content?.includes('port42 rpc works')
  },
  {
    name: 'terminal.exec — whoami',
    method: 'terminal.exec',
    args: { command: 'whoami' },
    check: r => typeof r?.content === 'string' && r.content.trim().length > 0
  }
];

// ─── runner ──────────────────────────────────────────────────────────────────

function run() {
  console.log(`\nPort42 RPC Test Suite`);
  console.log(`Connecting to ${WS_URL}...\n`);

  const ws = new WebSocket(WS_URL);
  const pending = new Map();       // callId → { resolve, name }
  let testIndex = 0;
  const results = [];

  function sendCall(test) {
    return new Promise(resolve => {
      const callId = crypto.randomUUID();
      pending.set(callId, { resolve, name: test.name });
      ws.send(JSON.stringify({
        type: 'call',
        call_id: callId,
        method: test.method,
        args: test.args
      }));
    });
  }

  async function runNext() {
    if (testIndex >= TESTS.length) {
      printResults();
      ws.close();
      return;
    }

    const test = TESTS[testIndex++];
    process.stdout.write(`  Testing ${test.name}... `);

    const payload = await sendCall(test);

    const passed = test.check(payload);
    const label = passed ? '\x1b[32mPASS\x1b[0m' : '\x1b[31mFAIL\x1b[0m';
    const detail = passed ? '' : `  → ${JSON.stringify(payload)}`;
    console.log(label + detail);
    results.push({ name: test.name, passed, payload });

    runNext();
  }

  function printResults() {
    const pass = results.filter(r => r.passed).length;
    const fail = results.length - pass;
    console.log(`\n  ${pass}/${results.length} passed` + (fail ? ` — ${fail} failed` : ''));
    if (fail > 0) process.exit(1);
  }

  ws.addEventListener('open', () => {
    console.log('Connected.\n');
  });

  ws.addEventListener('message', ({ data }) => {
    const env = JSON.parse(data);
    console.log('[raw]', JSON.stringify(env));

    if (env.type === 'no_auth') {
      ws.send(JSON.stringify({
        type: 'identify',
        sender_id: 'test-rpc-' + Date.now(),
        sender_name: 'test-rpc',
        is_host: false
      }));
    }

    if (env.type === 'welcome') {
      console.log('  >> Watch the Port42 app — it will show permission prompts.');
      console.log('  >> Approve each one to continue.\n');
      runNext();
    }

    if (env.type === 'response') {
      const entry = pending.get(env.call_id);
      if (entry) {
        pending.delete(env.call_id);
        entry.resolve(env.payload);
      }
    }

    if (env.type === 'error') {
      const entry = pending.get(env.call_id);
      if (entry) {
        pending.delete(env.call_id);
        entry.resolve({ error: env.error });
      } else {
        console.error('\n[gateway error]', env.error);
        ws.close();
      }
    }
  });

  ws.addEventListener('close', () => console.log('\nDisconnected.'));
  ws.addEventListener('error', e => {
    console.error(`\n[connection failed] ${e.message}`);
    console.error('Is Port42 running?');
    process.exit(1);
  });
}

run();
