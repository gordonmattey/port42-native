// The invite page (open.port42.ai): one page for every Port42. The link's fragment names the Mac, the
// relay and the port; the page is a guest-only Port42 in the browser. It does nothing on load but read
// the invite: no network call before the person clicks.

import { decodeCoupon, rightsSentence, isMove, expired } from './coupon.js';
import { Guest, explain } from './guest.js';

export const DOWNLOAD = 'https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg';

const $ = (doc, id) => doc.getElementById(id);

/// Wire the page. `deps` lets a test give its own window, storage and connect.
export function start({ win = window, doc = document, storage = safeStorage(win), connect } = {}) {
  const raw = win.location.hash.replace(/^#/, '');
  const coupon = decodeCoupon(raw);
  // The coupon leaves the address bar at once, so it is not left in history or shared by a screenshot.
  try { win.history.replaceState(null, '', win.location.pathname + win.location.search); } catch {}
  if (!coupon) { show(doc, 'broken'); return null; }

  $(doc, 'who').textContent = isMove(coupon)
    ? `${coupon.hostName} is giving you '${coupon.portTitle}'.`
    : `${coupon.hostName} shared '${coupon.portTitle}' with you.`;
  $(doc, 'what').textContent = isMove(coupon)
    ? 'It opens in Port42 as yours, and closes on their Mac. A move needs Port42.'
    : `You can ${rightsSentence(coupon.rights)} it.`;
  if (coupon.exp) $(doc, 'when').textContent = `This invite works until ${new Date(coupon.exp * 1000).toLocaleString()}.`;
  $(doc, 'open-app').href = 'port42://invite#' + raw;
  $(doc, 'get-app').href = DOWNLOAD;
  if (expired(coupon)) { $(doc, 'intro-note').textContent = 'This invite has expired. Ask for a new one.'; }
  if (isMove(coupon)) $(doc, 'open-here').hidden = true;
  if (coupon.code) $(doc, 'code-row').hidden = false;
  show(doc, 'intro');

  let guest = null;
  const frameState = { html: null, loads: 0 };
  $(doc, 'open-here').addEventListener('click', () => show(doc, 'join'));
  $(doc, 'join-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const name = $(doc, 'name').value.trim();
    const code = $(doc, 'code').value.trim();
    $(doc, 'join-error').textContent = '';
    $(doc, 'join-button').disabled = true;
    guest = new Guest({ coupon, storage, connect, ui: ui(doc, coupon, () => guest, frameState) });
    try {
      await guest.join({ name, code });
      show(doc, 'port');
    } catch (e) {
      $(doc, 'join-error').textContent = explain(e.code, coupon.hostName);
      $(doc, 'join-button').disabled = false;
    }
  });
  $(doc, 'chat-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const input = $(doc, 'chat-input');
    const text = input.value.trim();
    if (!text || !guest) return;
    input.value = '';
    try { await guest.post(text); } catch (e) { input.value = text; }
  });
  // The port's page talks to the guest only by message, and only from its own frame.
  win.addEventListener('message', async (ev) => {
    const frame = $(doc, 'frame');
    if (!guest || ev.source !== frame.contentWindow) return;
    const m = ev.data;
    // The frame is ready for the port's page (its own document, with the port's policy, not ours).
    if (m && m.port42 === 'ready' && frameState.html != null) {
      frame.contentWindow.postMessage({ port42: 'load', html: frameState.html }, '*');
      return;
    }
    if (!m || m.port42 !== 'call') return;
    try {
      const value = await guest.frameCall(m.method, Array.isArray(m.args) ? m.args : []);
      frame.contentWindow.postMessage({ port42: 'result', id: m.id, value }, '*');
    } catch (e) {
      const error = { code: e.code || 'error', message: e.message };
      for (const k of Object.keys(e)) if (!(k in error)) error[k] = e[k];
      frame.contentWindow.postMessage({ port42: 'result', id: m.id, error }, '*');
    }
  });
  return { coupon, guest: () => guest, frameState };
}

function ui(doc, coupon, guest, frameState) {
  return {
    // A fresh frame for each version of the page: it loads frame.html, says it is ready, and is sent
    // the page (see the message handler above).
    onPage(html) {
      frameState.html = html;
      $(doc, 'frame').src = 'frame.html?v=' + (++frameState.loads);
    },
    onData(detail) { $(doc, 'frame').contentWindow?.postMessage({ port42: 'data', detail }, '*'); },
    onEvent(kind, payload) { $(doc, 'frame').contentWindow?.postMessage({ port42: 'event', kind, payload }, '*'); },
    onChat(entries) {
      const list = $(doc, 'chat-list');
      list.textContent = '';
      for (const e of entries.slice(-100)) {
        const row = doc.createElement('div');
        row.className = 'entry';
        const who = doc.createElement('b');
        who.textContent = e.from?.name ?? '';
        row.append(who, doc.createTextNode(' ' + (e.text ?? '')));
        list.append(row);
      }
      list.scrollTop = list.scrollHeight;
    },
    onState({ online, message, final }) {
      doc.body.classList.toggle('offline', !online);
      $(doc, 'status').textContent = online ? '' : (message ?? '');
      $(doc, 'chat-input').disabled = !online;
      if (final) guest()?.stop();
    },
  };
}

function show(doc, section) {
  for (const s of ['broken', 'intro', 'join', 'port']) $(doc, s).hidden = s !== section;
}

function safeStorage(win) {
  try { return win.localStorage; } catch { return null; }
}
