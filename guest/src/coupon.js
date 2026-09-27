// The invite in a link's fragment, as InviteCoupon in Invites.swift makes it: base64url JSON naming the
// host's peer id, its relays, one port, the rights, a one-time nonce, an expiry and display names.

export function decodeCoupon(fragment) {
  const raw = (fragment ?? '').replace(/^#/, '');
  if (!raw) return null;
  let json;
  try {
    const b64 = raw.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((raw.length + 3) % 4);
    json = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
  } catch { return null; }
  const ok = json && json.v === 1 && typeof json.host === 'string' && json.host.length === 52
    && Array.isArray(json.relays) && json.relays.length > 0 && json.relays.every((r) => /^wss:\/\/|^ws:\/\//.test(r))
    && typeof json.port === 'string' && typeof json.nonce === 'string' && Array.isArray(json.rights);
  return ok ? json : null;
}

const WORDS = { see: 'see', use: 'use', edit: 'edit', wake_agents: 'wake', fork: 'copy', move: 'move' };

/// "see, use and edit": what the invite lets them do, in a sentence.
export function rightsSentence(rights) {
  const words = ['see', 'use', 'edit', 'wake_agents', 'fork'].filter((r) => rights.includes(r)).map((r) => WORDS[r]);
  if (words.length === 0) return 'nothing yet';
  return words.length === 1 ? words[0] : words.slice(0, -1).join(', ') + ' and ' + words.at(-1);
}

export const isMove = (c) => c.rights.includes('move');
export const expired = (c, now = Date.now()) => typeof c.exp === 'number' && c.exp * 1000 < now;
