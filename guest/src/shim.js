// The `window.port42` a shared port's page gets in the browser. The page runs in a sandboxed iframe
// with an opaque origin and no access to the guest's key or storage; every call it makes is a message
// to the parent page, which sends it to the host as the guest, and the host's rights decide.

/// The script put at the top of the port's page. `selfId` is the host's port id: the port the page is.
export function shimScript(selfId) {
  return `<script>(function(){
  var SELF = ${JSON.stringify(selfId)};
  var n = 0, pending = {}, listeners = {};
  function call(method, args) {
    return new Promise(function(resolve, reject) {
      var id = ++n; pending[id] = { resolve: resolve, reject: reject };
      parent.postMessage({ port42: 'call', id: id, method: method, args: args }, '*');
    });
  }
  window.addEventListener('message', function(ev) {
    if (ev.source !== parent) return;
    var m = ev.data;
    if (!m || typeof m.port42 !== 'string') return;
    if (m.port42 === 'result') {
      var p = pending[m.id]; if (!p) return; delete pending[m.id];
      if (m.error) { var e = new Error(m.error.message || m.error.code); for (var k in m.error) e[k] = m.error[k]; p.reject(e); }
      else p.resolve(m.value);
    } else if (m.port42 === 'data') {
      window.dispatchEvent(new CustomEvent('port42:data', { detail: m.detail }));
    } else if (m.port42 === 'event') {
      (listeners[m.kind] || []).forEach(function(f) { try { f(m.payload); } catch (e) { console.error(e); } });
    }
  });
  function ns(path) {
    return new Proxy(function() {}, {
      get: function(_, k) { return typeof k === 'string' ? ns(path ? path + '.' + k : k) : undefined; },
      apply: function(_, __, args) { return call(path, Array.prototype.slice.call(args)); }
    });
  }
  var impl = {
    self: Object.freeze({ id: SELF }),
    on: function(kind, f) { (listeners[kind] = listeners[kind] || []).push(f); }
  };
  window.port42 = new Proxy(impl, { get: function(t, k) {
    if (typeof k !== 'string') return undefined;
    return Object.prototype.hasOwnProperty.call(t, k) ? t[k] : ns(k);
  } });
})();</script>`;
}

/// The base style Port42 gives every port (the `<style data-port42>` block of the app's
/// PortWebViewFactory.wrapHTML). A copy, kept identical by GuestPortWrapTests on the Swift side.
export const BASE_CSS = `
  :root { --color-accent: #00ff41; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
  background: #111;
  color: #e0e0e0;
  font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
  font-size: 13px;
  line-height: 1.5;
  padding: 12px;
  overflow: auto;
  }
  a { color: #00ff41; }
  button, input, select, textarea {
  font-family: inherit;
  font-size: inherit;
  color: #e0e0e0;
  background: #1a1a1a;
  border: 1px solid #333;
  border-radius: 4px;
  padding: 6px 10px;
  outline: none;
  }
  button {
  cursor: pointer;
  background: #00ff41;
  color: #0a0a0a;
  border: none;
  font-weight: 600;
  padding: 6px 14px;
  }
  button:hover { opacity: 0.85; }
  input:focus, textarea:focus { border-color: #00ff41; }
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
`;

/// The port's page as the app gives it, so a shared port looks and runs the same in a browser (GM,
/// 2026-09-27: a shared port rendered in Times with its data missing). The page is wrapped with the
/// base style, and its scripts become ES modules as in the app: a page that awaits at top level, which
/// most do to load their storage, is a syntax error as a classic script and never ran. The shim goes
/// first, as a classic script, so `window.port42` exists before the page's modules run.
export function framedPage(selfId, html) {
  const body = String(html).replace(/<script>/g, '<script type="module">');
  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
    + '<meta name="viewport" content="width=device-width, initial-scale=1">'
    + shimScript(selfId)
    + '<style data-port42>' + BASE_CSS + '</style></head><body>' + body + '</body></html>';
}

/// Positional arguments to named ones, as BridgeArgs(positional:names:) does in the app.
export function named(args, names) {
  const out = {};
  names.forEach((name, i) => { if (i < args.length && args[i] !== undefined) out[name] = args[i]; });
  return out;
}
