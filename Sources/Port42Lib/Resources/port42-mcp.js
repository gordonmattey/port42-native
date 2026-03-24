#!/usr/bin/env node
// Port42 MCP Server
// Exposes Port42 bridge APIs to Claude Code, Gemini CLI, and any MCP-compatible tool.
// Requires Node.js 22+ (built-in WebSocket — no npm dependencies).

const GATEWAY = process.env.PORT42_GATEWAY ?? 'ws://127.0.0.1:4242';

// --- Gateway connection ---

const peerId = 'mcp-' + Math.random().toString(36).slice(2, 10);
const pending = new Map(); // callId -> { resolve, reject, timer }
let ws = null;
let ready = false;

function connect() {
    try {
        ws = new WebSocket(GATEWAY);
    } catch (e) {
        setTimeout(connect, 3000);
        return;
    }
    ws.onopen = () => {
        ws.send(JSON.stringify({ type: 'identify', sender_id: peerId, sender_name: 'port42-mcp' }));
    };
    ws.onmessage = ({ data }) => {
        try {
            const env = JSON.parse(data);
            if (env.type === 'welcome' || env.type === 'no_auth') {
                ready = true;
            }
            if (env.type === 'response' && env.call_id) {
                const p = pending.get(env.call_id);
                if (p) {
                    clearTimeout(p.timer);
                    pending.delete(env.call_id);
                    const content = env.payload?.content ?? JSON.stringify(env);
                    p.resolve(content);
                }
            }
            if (env.type === 'error' && env.call_id) {
                const p = pending.get(env.call_id);
                if (p) {
                    clearTimeout(p.timer);
                    pending.delete(env.call_id);
                    p.reject(new Error(env.error ?? 'Gateway error'));
                }
            }
        } catch {}
    };
    ws.onclose = () => {
        ready = false;
        setTimeout(connect, 3000);
    };
    ws.onerror = () => {};
}

function call(method, args = {}) {
    if (!ready) return Promise.reject(new Error('Port42 not connected — is Port42.app running?'));
    const callId = Math.random().toString(36).slice(2, 18);
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            if (pending.has(callId)) {
                pending.delete(callId);
                reject(new Error(`Call timed out: ${method}`));
            }
        }, 30_000);
        pending.set(callId, { resolve, reject, timer });
        ws.send(JSON.stringify({ type: 'call', call_id: callId, method, args }));
    });
}

// --- MCP Protocol (JSON-RPC 2.0 over stdio) ---

const TOOLS = [
    {
        name: 'port42',
        description: [
            'Call any Port42 bridge API on the host Mac.',
            'Available methods include: terminal.exec, screen.capture, clipboard.read, clipboard.write,',
            'fs.read, fs.write, browser.open, browser.navigate, browser.capture, browser.text,',
            'browser.execute, browser.close, notify.send, automation.runAppleScript, automation.runJXA,',
            'audio.speak, messages.send, messages.recent, companions.invoke, ai.complete, and more.',
            'See the Port42 API reference in your global context (CLAUDE.md / GEMINI.md).',
        ].join(' '),
        inputSchema: {
            type: 'object',
            properties: {
                method: {
                    type: 'string',
                    description: 'Bridge method name, e.g. "terminal.exec" or "screen.capture"',
                },
                args: {
                    type: 'object',
                    description: 'Method arguments as a JSON object, e.g. {"command": "ls -la"}',
                    default: {},
                },
            },
            required: ['method'],
        },
    },
];

process.stdin.setEncoding('utf8');
let buf = '';
process.stdin.on('data', chunk => {
    buf += chunk;
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
        if (line.trim()) {
            try { handle(JSON.parse(line)); } catch {}
        }
    }
});

function reply(id, result) {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
}

function replyError(id, code, message) {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n');
}

async function handle({ id, method, params = {} }) {
    if (method === 'initialize') {
        reply(id, {
            protocolVersion: '2024-11-05',
            capabilities: { tools: {} },
            serverInfo: { name: 'port42', version: '1.0' },
        });
    } else if (method === 'tools/list') {
        reply(id, { tools: TOOLS });
    } else if (method === 'tools/call') {
        const { name, arguments: a = {} } = params;
        if (name !== 'port42') {
            replyError(id, -32601, `Unknown tool: ${name}`);
            return;
        }
        try {
            const result = await call(a.method, a.args ?? {});
            const text = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
            reply(id, { content: [{ type: 'text', text }] });
        } catch (e) {
            reply(id, { content: [{ type: 'text', text: `Error: ${e.message}` }], isError: true });
        }
    } else if (method === 'ping') {
        reply(id, {});
    }
    // notifications (initialized, cancelled) — no response needed
}

connect();
