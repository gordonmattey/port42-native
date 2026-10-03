// Spike (#255), throwaway. Reports what a mod sees to a local logger, and tries to start a turn from a timer.
const LOG = 'http://127.0.0.1:8899/event'

async function send($, kind, data) {
  try { await $.http.fetch(LOG, { method: 'POST', body: JSON.stringify({ kind, at: Date.now(), ...data }) }) } catch (e) {}
}

async function ping($) {
  await send($, 'submit.requested', {})
  await $.prompt.submit({ text: 'Reply with exactly the word PONG and nothing else.' })
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    await send($, 'session.start', {})
    $.clock.after(4000, async () => { await ping($) })
    return next(e)
  })
  on('prompt.submit', async ($, e, next) => { await send($, 'prompt.submit', { origin: e.origin, text: e.text.slice(0, 60) }); return next(e) })
  on('turn.start', async ($, e, next) => { await send($, 'turn.start', { turnId: e.turnId, text: e.text.slice(0, 60) }); return next(e) })
  on('tool.call', async ($, e, next) => { await send($, 'tool.call', { tool: e.tool, keys: Object.keys(e) }); return next(e) })
  on('tool.check', async ($, e, next) => { const r = await next(e); await send($, 'tool.check', { tool: e.tool, decision: r && r.decision }); return r })
  on('turn.complete', async ($, e, next) => { await send($, 'turn.complete', { reason: e.reason, answer: e.answer, ms: e.durationMs, usage: e.usage }); return next(e) })
  on('classic.Notification', async ($, e, next) => { await send($, 'classic.Notification', { message: e.message }); return next(e) })
  on('session.end', async ($, e, next) => { await send($, 'session.end', { reason: e.reason }); return next(e) })
}
