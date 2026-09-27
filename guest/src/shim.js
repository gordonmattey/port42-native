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

/// The port's page as the iframe's srcdoc: the shim first, then the page.
export function framedPage(selfId, html) { return shimScript(selfId) + html; }

/// Positional arguments to named ones, as BridgeArgs(positional:names:) does in the app.
export function named(args, names) {
  const out = {};
  names.forEach((name, i) => { if (i < args.length && args[i] !== undefined) out[name] = args[i]; });
  return out;
}
