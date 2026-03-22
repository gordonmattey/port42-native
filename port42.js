#!/usr/bin/env node
/**
 * Port42 CLI bridge — call any Port42 gateway API from the terminal.
 * Node 22+ required (built-in WebSocket + crypto).
 *
 * Usage:
 *   node port42.js <method> [args-json]
 *
 * Examples:
 *   node port42.js clipboard.read
 *   node port42.js terminal.exec '{"command":"ls ~/Desktop"}'
 *   node port42.js clipboard.write '{"text":"hello from cli"}'
 *   node port42.js screen_capture '{}'
 *   node port42.js files.list '{"path":"~/"}'
 *
 * Output:
 *   Prints the response content to stdout (plain text or JSON).
 *   Exits 0 on success, 1 on error.
 */

const method = process.argv[2];
const argsRaw = process.argv[3] ?? '{}';

if (!method) {
  console.error('Usage: node port42.js <method> [args-json]');
  console.error('');
  console.error('Examples:');
  console.error('  node port42.js clipboard.read');
  console.error('  node port42.js terminal.exec \'{"command":"whoami"}\'');
  process.exit(1);
}

let args;
try {
  args = JSON.parse(argsRaw);
} catch {
  console.error(`Invalid JSON args: ${argsRaw}`);
  process.exit(1);
}

const ws = new WebSocket('ws://127.0.0.1:4242/ws');
let callId = null;
let done = false;

const timeout = setTimeout(() => {
  if (!done) {
    console.error('Timed out — no response after 30s. Is Port42 running?');
    ws.close();
    process.exit(1);
  }
}, 30_000);

ws.addEventListener('error', e => {
  console.error(`Connection failed: ${e.message}\nIs Port42 running?`);
  clearTimeout(timeout);
  process.exit(1);
});

ws.addEventListener('message', ({ data }) => {
  const env = JSON.parse(data);

  if (env.type === 'no_auth') {
    ws.send(JSON.stringify({
      type: 'identify',
      sender_id: 'port42-cli-' + Date.now(),
      sender_name: 'port42-cli',
      is_host: false
    }));
  }

  if (env.type === 'welcome') {
    callId = crypto.randomUUID();
    ws.send(JSON.stringify({
      type: 'call',
      call_id: callId,
      method,
      args
    }));
  }

  if (env.type === 'response' && env.call_id === callId) {
    done = true;
    clearTimeout(timeout);

    const content = env.payload?.content;
    if (content !== undefined && content !== null) {
      // Try to pretty-print JSON, fall back to raw string
      try {
        const parsed = JSON.parse(content);
        console.log(JSON.stringify(parsed, null, 2));
      } catch {
        process.stdout.write(content);
        if (!content.endsWith('\n')) process.stdout.write('\n');
      }
    } else {
      console.log('(empty response)');
    }

    ws.close();
  }

  if (env.type === 'error' && !env.call_id) {
    // Gateway-level error (not a tool error)
    done = true;
    clearTimeout(timeout);
    console.error(`Gateway error: ${env.error}`);
    ws.close();
    process.exit(1);
  }
});

ws.addEventListener('close', () => {
  if (!done) process.exit(1);
});
