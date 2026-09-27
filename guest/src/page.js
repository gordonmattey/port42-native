// The invite page (tele.port42.ai): one page for every Port42. The link's fragment names the Mac, the
// relay and the port; the page is a guest-only Port42 in the browser, and the port is the page
// (Gordon). Joining takes one click the first time: a link previewer that runs the page's script would
// otherwise spend the one-time invite. A browser that has joined this port before opens it at once.

import { decodeCoupon, rightsSentence, isMove, expired } from './coupon.js';
import { Guest, explain } from './guest.js';

export const DOWNLOAD = 'https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg';
const JOINED_KEY = 'port42.guest.joined';
const NAME_KEY = 'port42.guest.name';

const $ = (doc, id) => doc.getElementById(id);

/// Wire the page. `deps` lets a test give its own window, storage and connect.
export function start({ win = window, doc = document, storage = safeStorage(win), connect } = {}) {
  // The invite leaves the address bar, but this tab keeps it, so a refresh reopens the port.
  const tab = safeSession(win);
  const raw = win.location.hash.replace(/^#/, '') || read(tab, TAB_KEY) || '';
  // The coupon leaves the address bar at once, so it is not left in history or shared by a screenshot.
  try { win.history.replaceState(null, '', win.location.pathname + win.location.search); } catch {}
  let coupon = null, guest = null;
  const frameState = { html: null, loads: 0 };
  const chatSeen = { at: 0, last: 0 };
  $(doc, 'get-app').href = DOWNLOAD;

  // Home: paste the invite link someone sent, anywhere on the page, and it opens (Gordon: no field to
  // click, no button). A clicked link skips this.
  const openPasted = (text) => {
    text = (text ?? '').trim();
    if (!text) return;
    if (!invite(text.includes('#') ? text.slice(text.indexOf('#') + 1) : text)) {
      $(doc, 'paste-error').textContent = 'That is not an invite link Port42 can read.';
    }
  };
  doc.addEventListener('paste', (ev) => {
    if (coupon || $(doc, 'paste').hidden) return;
    ev.preventDefault();
    openPasted(ev.clipboardData?.getData('text') ?? '');
  });
  $(doc, 'paste-form').addEventListener('submit', (ev) => { ev.preventDefault(); openPasted($(doc, 'paste-input').value); });

  function invite(frag) {
    const c = decodeCoupon(frag);
    if (!c) return false;
    coupon = c;
    write(tab, TAB_KEY, frag);
    present(frag);
    return true;
  }

  /// The port, with its header and, until joined, the card that joins it.
  function present(frag) {
    $(doc, 'title').textContent = coupon.portTitle;
    $(doc, 'pill').textContent = `${coupon.hostName}'s`;
    $(doc, 'pill').hidden = false;
    $(doc, 'open-app').href = 'port42://invite#' + frag;
    $(doc, 'open-app').hidden = false;
    $(doc, 'who').textContent = isMove(coupon)
      ? `${coupon.hostName} is giving you '${coupon.portTitle}'.`
      : `${coupon.hostName} shared '${coupon.portTitle}' with you.`;
    $(doc, 'what').textContent = isMove(coupon)
      ? 'It opens in Port42 as yours, and closes on their Mac. Open it in Port42.'
      : `You can ${rightsSentence(coupon.rights)} it.`;
    if (coupon.exp) $(doc, 'when').textContent = `This invite works until ${new Date(coupon.exp * 1000).toLocaleString()}.`;
    if (expired(coupon)) $(doc, 'join-error').textContent = 'This invite has expired. Ask for a new one.';
    $(doc, 'code-row').hidden = !coupon.code;
    $(doc, 'join-button').hidden = isMove(coupon);
    $(doc, 'name').hidden = isMove(coupon);
    $(doc, 'name').value = read(storage, NAME_KEY) ?? '';
    show(doc, 'port');
    // Back again: this browser has joined this port before, so it opens without asking.
    if (!isMove(coupon) && joinedBefore(storage, coupon)) join();
  }

  async function join() {
    const name = $(doc, 'name').value.trim();
    const code = $(doc, 'code').value.trim();
    $(doc, 'join-error').textContent = '';
    $(doc, 'join-button').disabled = true;
    guest = new Guest({ coupon, storage, connect, ui: ui(doc, () => guest, frameState, chatSeen) });
    try {
      await guest.join({ name, code });
      write(storage, NAME_KEY, name);
      rememberJoined(storage, coupon);
      $(doc, 'gate').hidden = true;
      $(doc, 'chat-toggle').hidden = false;
    } catch (e) {
      $(doc, 'join-error').textContent = explain(e.code, coupon.hostName);
      $(doc, 'join-button').disabled = false;
    }
  }

  $(doc, 'gate').addEventListener('submit', (ev) => { ev.preventDefault(); join(); });
  // The chat drops down from the title bar over the port, as on a tile in Port42.
  // Drag the chat's bottom edge to set its height, as in Port42; the height is remembered.
  const CHAT_H = 'port42.guest.chatHeight';
  const setChatHeight = (px) => {
    const room = $(doc, 'body').clientHeight || 600;
    const h = Math.round(Math.max(120, Math.min(px, room - 60)));
    $(doc, 'chat').style.height = h + 'px';
    return h;
  };
  const savedH = Number(read(storage, CHAT_H));
  if (savedH > 0) setChatHeight(savedH);
  $(doc, 'chat-resize').addEventListener('pointerdown', (down) => {
    down.preventDefault();
    const startY = down.clientY, startH = $(doc, 'chat').getBoundingClientRect().height || $(doc, 'chat').offsetHeight;
    const move = (ev) => setChatHeight(startH + (ev.clientY - startY));
    const up = (ev) => {
      write(storage, CHAT_H, String(setChatHeight(startH + (ev.clientY - startY))));
      win.removeEventListener('pointermove', move);
      win.removeEventListener('pointerup', up);
    };
    win.addEventListener('pointermove', move);
    win.addEventListener('pointerup', up);
  });
  $(doc, 'chat-toggle').addEventListener('click', () => {
    const open = !$(doc, 'chat').classList.contains('open');
    $(doc, 'chat').classList.toggle('open', open);
    $(doc, 'chat-toggle').classList.toggle('open', open);
    if (open) { chatSeen.at = chatSeen.last; $(doc, 'chat-count').hidden = true; $(doc, 'chat-input').focus(); }
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

  if (raw && !invite(raw)) $(doc, 'paste-error').textContent = 'That link is not an invite Port42 can read. Paste it again, whole.';
  if (!coupon) show(doc, 'paste');
  return { coupon: () => coupon, guest: () => guest, frameState };
}

function ui(doc, guest, frameState, chatSeen) {
  return {
    // A fresh frame for each version of the page: it loads frame.html, says it is ready, and is sent
    // the page (see the message handler above).
    onPage(html) {
      frameState.html = html;
      $(doc, 'frame').src = 'frame.html?v=' + (++frameState.loads);
    },
    onData(detail) { $(doc, 'frame').contentWindow?.postMessage({ port42: 'data', detail }, '*'); },
    onEvent(kind, payload) { $(doc, 'frame').contentWindow?.postMessage({ port42: 'event', kind, payload }, '*'); },
    // As PortChatPanel: yours on the right, others on the left under their name, a run of one
    // person's messages grouped; Port42's own lines quiet.
    onChat(entries) {
      const list = $(doc, 'chat-list');
      const me = guest()?.me?.id;
      list.textContent = '';
      if (!entries.length) {
        const empty = doc.createElement('p');
        empty.className = 'empty';
        empty.textContent = 'No messages yet. What you say here belongs to this port.';
        list.append(empty);
      }
      let run = null, runFrom = null;
      for (const e of entries.slice(-100)) {
        const from = e.from?.id ?? '';
        if (!run || from !== runFrom) {
          run = doc.createElement('div');
          const mine = me && (from === me || from.startsWith(me + '/'));
          run.className = 'run' + (mine ? ' mine' : '') + (e.from?.kind === 'system' ? ' system' : '');
          if (!mine && e.from?.kind !== 'system') {
            const who = doc.createElement('div');
            who.className = 'who';
            who.textContent = e.from?.name ?? '';
            run.append(who);
          }
          list.append(run); runFrom = from;
        }
        const msg = doc.createElement('div');
        msg.className = 'msg';
        msg.textContent = e.text ?? '';
        run.append(msg);
      }
      list.scrollTop = list.scrollHeight;
      // Who is here, and what has not been read, on the chat button.
      const people = [...new Map(entries.filter((e) => e.from?.kind !== 'system').map((e) => [e.from?.id, e.from?.name])).values()].slice(-3);
      const strip = $(doc, 'chat-people');
      strip.textContent = '';
      for (const name of people) {
        const a = doc.createElement('span');
        a.className = 'avatar';
        a.style.background = `hsl(${[...(name ?? '')].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7)} 70% 60%)`;
        a.textContent = (name ?? '?').slice(0, 1).toUpperCase();
        strip.append(a);
      }
      chatSeen.last = entries.at(-1)?.seq ?? 0;
      if ($(doc, 'chat').classList.contains('open')) chatSeen.at = chatSeen.last;
      const unread = entries.filter((e) => e.seq > chatSeen.at && e.from?.kind !== 'system').length;
      $(doc, 'chat-count').textContent = String(unread);
      $(doc, 'chat-count').hidden = unread === 0;
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
  for (const s of ['paste', 'port']) $(doc, s).hidden = s !== section;
}

const portKey = (c) => `${c.host}/${c.port}`;
function joinedBefore(storage, c) {
  try { return JSON.parse(read(storage, JOINED_KEY) ?? '[]').includes(portKey(c)); } catch { return false; }
}
function rememberJoined(storage, c) {
  let list = [];
  try { list = JSON.parse(read(storage, JOINED_KEY) ?? '[]'); } catch {}
  if (!list.includes(portKey(c))) write(storage, JOINED_KEY, JSON.stringify([...list, portKey(c)].slice(-200)));
}
function read(storage, k) { try { return storage?.getItem(k) ?? null; } catch { return null; } }
function write(storage, k, v) { try { storage?.setItem(k, v); } catch {} }

const TAB_KEY = 'port42.guest.invite';
function safeSession(win) {
  try { return win.sessionStorage; } catch { return null; }
}

function safeStorage(win) {
  try { return win.localStorage; } catch { return null; }
}
