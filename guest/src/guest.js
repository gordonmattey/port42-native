// A browser guest of one shared port: its identity, its session to the host, the port's page in a
// sandboxed frame, the port's chat, and what it says when the host's Mac is away. The frame never
// holds the key: it can only ask this, by message, and this asks the host as the guest.

import { connect as realConnect, Refusal } from './client.js';
import { loadIdentity as loadKeys, v1Identity } from './keys.js';
import { framedPage, named, namesItsPort } from './shim.js';
import METHODS from './methods.json' with { type: 'json' };

/// This browser's guest identity with its older, seed-based keys: made on the first Join, kept for
/// port42's origin, so a refresh or a return visit is the same guest. Clearing the site's data makes a
/// new one. A guest whose host accepts it moves to keys the page cannot read (keys.js, GST-02).
export function loadIdentity(storage) { return v1Identity(storage); }

/// What each refusal says to a person.
export function explain(code, hostName = 'The sharer') {
  switch (code) {
    case 'host_offline': return `${hostName}'s Mac is offline or asleep. This reconnects on its own.`;
    case 'used': return 'This invite has already been used. Ask for a new one.';
    case 'expired': return 'This invite has expired. Ask for a new one.';
    case 'revoked': return 'This invite was withdrawn.';
    case 'wrong_code': return 'That code is not right.';
    case 'locked': return 'Too many wrong codes: this invite no longer works.';
    case 'gone': return 'The port this invite was for is no longer there.';
    case 'not_granted': return `${hostName} stopped sharing this port, or it does not allow that.`;
    case 'rate_limited': return 'Too many tries. Wait a minute and try again.';
    case 'refused': return `${hostName}'s Mac did not accept the connection.`;
    case 'host_outdated': return `${hostName} needs to update Port42 and send you a new link.`;
    default: return 'Something went wrong reaching the port.';
  }
}

export class Guest {
  /// `ui` receives what to show: onPage(srcdoc), onData(detail), onEvent(kind, payload),
  /// onChat(entries), onState({ online, message }).
  constructor({ coupon, storage, keyStore = null, subtle, connect = realConnect, ui, retryMs = 5000 }) {
    this.coupon = coupon;
    this.storage = storage;
    this.keyStore = keyStore;
    this.subtle = subtle;
    this.me = null;              // loaded on the first open, from what this invite's host accepts
    this.connect = connect;
    this.ui = ui;
    this.retryMs = retryMs;
    this.session = null;
    this.chat = [];
    this.stopped = false;
  }

  /// Join: connect, redeem the invite (again, harmlessly, for a returning guest), load the page and
  /// the chat, and follow the port. Throws a Refusal the page shows.
  async join({ name, code }) {
    this.name = name || 'a guest';
    this.code = code;
    await this.open();
  }

  async open() {
    const c = this.coupon;
    this.me ??= await loadKeys({ storage: this.storage, store: this.keyStore, coupon: c,
                                 ...(this.subtle ? { subtle: this.subtle } : {}) });
    const s = await this.connect({ relays: c.relays, host: c.host, identity: this.me });
    try {
      const args = { nonce: c.nonce, name: this.name };
      if (this.code) args.code = this.code;
      await s.call('invite.redeem', args);
    } catch (e) {
      s.close();
      throw e instanceof Refusal && e.reason ? new Refusal(e.reason, e.message) : e;
    }
    this.session = s;
    s.onEnd = () => this.lost();
    this.ui.onState({ online: true });
    await this.refresh();
    await this.loadChat();
    s.call('port.subscribe', { id: c.port }, { onStream: (ev) => this.event(ev) }).catch(() => {});
  }

  async refresh() {
    const html = await this.session.call('port.getHtml', { id: this.coupon.port });
    this.ui.onPage(framedPage(this.coupon.port, typeof html === 'string' ? html : ''));
  }

  async loadChat() {
    try {
      const out = await this.session.call('chat.read', { port: this.coupon.port });
      this.chat = out?.entries ?? [];
      this.ui.onChat(this.chat);
    } catch { /* no chat right: the chat stays empty */ }
  }

  event(ev) {
    if (!ev || typeof ev !== 'object') return;
    if (ev.kind === 'state') { this.refresh().catch(() => {}); return; }
    if (ev.kind === 'push') { this.ui.onData(ev.payload); return; }
    if (ev.kind === 'chat') {
      if (!this.chat.some((e) => e.seq === ev.payload?.seq)) { this.chat.push(ev.payload); this.ui.onChat(this.chat); }
      return;
    }
    this.ui.onEvent(ev.kind, ev.payload);
  }

  /// A call from the port's page, positional as the page makes it. The host's own rights decide.
  async frameCall(method, args) {
    // The user a page greets is whoever is viewing it: this guest, answered here.
    if (method === 'user.get') return { id: this.me?.id, displayName: this.name ?? 'a guest' };
    if (!this.session) throw new Refusal('host_offline', explain('host_offline', this.coupon.hostName));
    const names = METHODS[method];
    if (!names) throw new Refusal('not_granted', `${method} is not available to a guest`);
    const call = named(args, names);
    if (namesItsPort(method) && call.port === undefined) call.port = this.coupon.port;
    return this.session.call(method, call);
  }

  async post(text) {
    if (!this.session) throw new Refusal('host_offline', explain('host_offline', this.coupon.hostName));
    await this.session.call('chat.post', { port: this.coupon.port, text });
  }

  lost() {
    this.session = null;
    if (this.stopped) return;
    this.ui.onState({ online: false, message: explain('host_offline', this.coupon.hostName) });
    const retry = async () => {
      if (this.stopped || this.session) return;
      try { await this.open(); }
      catch (e) {
        if (e instanceof Refusal && e.code !== 'host_offline') {
          this.ui.onState({ online: false, message: explain(e.code, this.coupon.hostName), final: true });
          return;
        }
        setTimeout(retry, this.retryMs);
      }
    };
    setTimeout(retry, this.retryMs);
  }

  stop() { this.stopped = true; this.session?.close(); }
}
