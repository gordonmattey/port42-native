package main

// SPIKE · the browser guest (docs/plan-web-port-sharing.md, phase 0).
//
// Served BY THE GATEWAY, deliberately. A page from any other origin cannot call `/call` at all:
// there are no CORS headers on that door, and adding them would let every website you visit attempt
// calls against your local gateway. Same-origin needs no CORS and opens no new surface. `/ws` already
// accepts any origin, so only the HTTP half was ever in question.
//
// What this proves: a browser with no Port42 installed renders a live port hosted elsewhere, sees it
// change, and drives it back. Nothing here is a product surface — the token arrives in the query
// string, which phase 2 replaces with a one-time invite, and the caller is a hand-made client rather
// than the ephemeral guest of phase 1.
//
// NOTE FOR EDITORS: this is a Go raw string, so it cannot contain a backtick. The JS below uses
// string concatenation rather than template literals for that reason alone.

const guestPage = `<!doctype html>
<meta charset="utf-8">
<title>Port42 · shared port</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font:13px ui-monospace,SFMono-Regular,Menlo,monospace;
         background:#0b0f0e; color:#d6e2df; display:flex; flex-direction:column; height:100vh; }
  header { padding:8px 12px; border-bottom:1px solid #1d2725; display:flex; gap:12px; align-items:center; }
  .dot { width:8px; height:8px; border-radius:50%; background:#555; }
  .dot.on { background:#00d4aa; }
  .grow { flex:1; }
  input, button { font:inherit; background:#121a18; color:#d6e2df;
                  border:1px solid #223029; border-radius:4px; padding:4px 8px; }
  button { cursor:pointer; }
  iframe { flex:1; width:100%; border:0; background:#fff; }
  #log { height:120px; overflow:auto; padding:6px 12px; border-top:1px solid #1d2725;
         white-space:pre-wrap; color:#7f918c; }
  .k { color:#00d4aa; }
</style>
<header>
  <span class="dot" id="dot"></span>
  <span id="title">connecting…</span>
  <span class="grow"></span>
  <input id="line" placeholder="type something to push" size="28">
  <button id="send">push</button>
</header>
<iframe id="surface" sandbox="allow-scripts"></iframe>
<div id="log"></div>
<script>
(function () {
  var q = new URLSearchParams(location.search);
  var portId = q.get("id") || "";
  var token  = q.get("token") || "";
  var origin = location.origin;
  var log = document.getElementById("log");
  var surface = document.getElementById("surface");
  var stateToken = null;

  function say(k, m) {
    log.textContent += "[" + k + "] " + m + "\n";
    log.scrollTop = log.scrollHeight;
  }

  // ONE door out of this page. Everything the guest does — the initial read, the shim's calls, the
  // push button — goes through here, so the credential lives in exactly one place.
  function call(method, args) {
    return fetch(origin + "/call", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + token },
      body: JSON.stringify({ method: method, args: args || {} })
    }).then(function (r) { return r.json(); }).then(function (env) {
      var c = env.content;
      try { c = JSON.parse(c); } catch (e) {}
      if (c && c.error) {
        // CARRY 'current'. The refusal is designed to hand back the state to compose against, and a
        // client that stringifies the error throws the fix away — which is exactly what this page
        // did on its first run, turning a one-retry self-correction into a dead end.
        var e = new Error(c.code + ": " + c.error);
        e.code = c.code; e.current = c.current || (c.details && c.details.current);
        throw e;
      }
      return c;
    });
  }

  // The port's own JS expects window.port42 in-process. Here it is not, so the shim forwards every
  // call to the HOST. This is CR1's change made concrete: a shared port's bridge calls are remote.
  // The iframe is sandboxed and never sees the token — it asks the parent, which holds it.
  var SHIM = "<script>(function(){" +
    "var n=0,waiting={};" +
    "window.addEventListener('message',function(e){" +
      "var d=e.data||{};" +
      "if(d.__p42reply&&waiting[d.id]){waiting[d.id](d.ok,d.value);delete waiting[d.id];}" +
      "if(d.__p42event&&window.port42&&window.port42._emit){window.port42._emit(d.kind,d.payload);}" +
    "});" +
    "function send(method,args){return new Promise(function(res,rej){" +
      "var id=++n;waiting[id]=function(ok,v){ok?res(v):rej(new Error(v));};" +
      "parent.postMessage({__p42call:1,id:id,method:method,args:args},'*');});}" +
    "var handlers={};" +
    "window.port42=new Proxy({_emit:function(k,p){(handlers[k]||[]).forEach(function(f){f(p);});}," +
      "on:function(k,f){(handlers[k]=handlers[k]||[]).push(f);}}," +
      "{get:function(t,p){if(p in t)return t[p];" +
        "return function(a){return send(String(p),a||{});};}});" +
  "})();<\/script>";

  window.addEventListener("message", function (e) {
    var d = e.data || {};
    if (!d.__p42call) return;
    call(d.method, d.args).then(function (v) {
      say("shim", d.method + " ok");
      surface.contentWindow.postMessage({ __p42reply: 1, id: d.id, ok: true, value: v }, "*");
    }).catch(function (err) {
      say("shim", d.method + " REFUSED " + err.message);
      surface.contentWindow.postMessage({ __p42reply: 1, id: d.id, ok: false, value: err.message }, "*");
    });
  });

  function render() {
    return call("port.getHtml", { id: portId }).then(function (r) {
      var html = (r && r.html) || (typeof r === "string" ? r : "");
      // The shim goes in FIRST so it exists before the port's own scripts run.
      surface.srcdoc = SHIM + html;
      say("read", "rendered " + html.length + " bytes");
    });
  }

  // Live events. WS only: port.subscribe is refused on /call, because a subscription there could
  // only hang until the timeout.
  function watch() {
    var ws = new WebSocket((origin.replace(/^http/, "ws")) + "/ws");
    var me = "guest-" + Math.random().toString(36).slice(2, 8);
    ws.onopen = function () {
      ws.send(JSON.stringify({ type: "identify", sender_id: me, credential: token }));
      ws.send(JSON.stringify({ type: "call", call_id: "sub-1", sender_id: me,
                               method: "port.subscribe", args: { id: portId } }));
      document.getElementById("dot").className = "dot on";
      say("ws", "subscribed");
    };
    ws.onclose = function () { document.getElementById("dot").className = "dot"; say("ws", "closed"); };
    ws.onmessage = function (m) {
      var env; try { env = JSON.parse(m.data); } catch (e) { return; }
      if (env.type !== "stream") return;
      var ev; try { ev = JSON.parse(env.payload && env.payload.content); } catch (e) { return; }
      if (!ev || !ev.kind) return;
      if (ev.token) stateToken = ev.token;
      say("event", ev.kind + (ev.token ? " @" + ev.token : ""));

      // G1: the port's surface was REPLACED, so re-read. Without the state kind there is no event
      // here at all, which is why this had to be built before the page could converge.
      if (ev.kind === "state") { render(); return; }
      // Everything else is delivered to the port's own JS, exactly as it would be locally.
      surface.contentWindow.postMessage({ __p42event: 1, kind: ev.kind, payload: ev.payload }, "*");
    };
  }

  // The payload param is 'data', not 'text'. It always was, and sending 'text' APPEARED to work:
  // the missing 'data' was defaulted to null, so the write landed, moved the token and delivered
  // nothing. The required-args pass turned that silent no-op into missing_arg, which is how this
  // page's first push was found to have been pushing nothing at all.
  document.getElementById("send").onclick = function () {
    var text = document.getElementById("line").value;
    if (!text) return;
    // A write must say what it composed against. If we have not seen a token yet, the refusal
    // carries 'current' and one retry lands — the designed self-correcting path.
    call("port.push", { id: portId, data: text, token: stateToken || "" })
      .then(function (r) { stateToken = r && r.token || stateToken; say("push", "ok @" + stateToken); })
      .catch(function (err) {
        if (!err.current) { say("push", "failed " + err.message); return; }
        stateToken = err.current;
        say("push", "refused (" + err.code + "), retrying against " + stateToken);
        call("port.push", { id: portId, data: text, token: stateToken })
          .then(function (r) { stateToken = r && r.token || stateToken; say("push", "ok @" + stateToken); })
          .catch(function (e2) { say("push", "failed twice " + e2.message); });
      });
  };

  if (!portId || !token) {
    say("setup", "open with ?id=<portId>&token=<clientToken>");
  } else {
    document.getElementById("title").textContent = "port " + portId.slice(0, 8) + "…";
    render().then(watch).catch(function (e) { say("setup", e.message); });
  }
})();
</script>
`
