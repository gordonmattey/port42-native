"""A minimal Port42 client for the scenario harness: HTTP /call and the /ws door.

The caller is whoever owns the token file named by P42_TOKEN_FILE. The harness never borrows another
tool's token, and it refuses the production port.
"""
import json, os, sys, urllib.request, urllib.error, asyncio, uuid

PROD_PORT = 4242


class Refused(Exception):
    def __init__(self, body):
        self.body = body
        super().__init__(json.dumps(body))

    @property
    def code(self):
        return self.body.get("code") if isinstance(self.body, dict) else None


def _unwrap(raw):
    c = raw.get("content", raw) if isinstance(raw, dict) else raw
    if isinstance(c, str):
        try:
            c = json.loads(c)
        except ValueError:
            pass
    return c


class Client:
    def __init__(self, port, token_file):
        if int(port) == PROD_PORT:
            sys.exit("refusing to run against the production instance (port 4242)")
        if not token_file or not os.path.exists(token_file):
            sys.exit("P42_TOKEN_FILE must name this harness's own token file (Settings → Access)")
        self.port = int(port)
        self.token_file = token_file

    @property
    def token(self):
        # Read at call time: the file is re-issued when the app restarts.
        return open(self.token_file).read().strip()

    @property
    def base(self):
        return f"http://127.0.0.1:{self.port}"

    def call(self, method, args=None, timeout=30, raise_on_error=True):
        body = json.dumps({"method": method, "args": args or {}}).encode()
        req = urllib.request.Request(self.base + "/call", data=body, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            raw = json.load(urllib.request.urlopen(req, timeout=timeout))
        except urllib.error.HTTPError as e:
            raw = json.loads(e.read() or b"{}")
        out = _unwrap(raw)
        if raise_on_error and isinstance(out, dict) and "error" in out and "code" in out:
            raise Refused(out)
        return out

    def healthy(self):
        try:
            return urllib.request.urlopen(self.base + "/health", timeout=2).read() == b"ok"
        except Exception:
            return False

    def host_up(self):
        try:
            self.call("space.current", timeout=3)
            return True
        except Exception:
            return False


class WSGuest:
    """A caller on the /ws door that gives its credential ONCE, at identify, and never again.

    That is how the browser guest behaves, so it is what the harness tests.
    """

    def __init__(self, client, credential_per_call=False):
        self.client = client
        self.per_call = credential_per_call
        self.me = "harness-" + uuid.uuid4().hex[:6]
        self.pending = {}
        self.frames = []

    async def __aenter__(self):
        import websockets
        self.ws = await websockets.connect(f"ws://127.0.0.1:{self.client.port}/ws")
        first = json.loads(await self.ws.recv())
        if first.get("type") not in ("no_auth", "challenge"):
            raise RuntimeError(f"unexpected greeting {first}")
        await self.ws.send(json.dumps({"type": "identify", "sender_id": self.me,
                                       "credential": self.client.token}))
        self.reader = asyncio.create_task(self._read())
        return self

    async def __aexit__(self, *a):
        self.reader.cancel()
        await self.ws.close()

    async def _read(self):
        async for m in self.ws:
            env = json.loads(m)
            cid = env.get("call_id")
            payload = _unwrap((env.get("payload") or {})) if env.get("payload") else None
            if env.get("type") == "stream":
                self.frames.append(payload)
            elif env.get("type") in ("response", "error") and cid in self.pending:
                body = payload if env.get("type") == "response" else {"error": env.get("error"), "code": env.get("code")}
                self.pending.pop(cid).set_result(body)

    async def call(self, method, args, timeout=15):
        cid = "c" + uuid.uuid4().hex[:8]
        fut = asyncio.get_event_loop().create_future()
        self.pending[cid] = fut
        env = {"type": "call", "call_id": cid, "sender_id": self.me, "method": method, "args": args}
        if self.per_call:
            env["credential"] = self.client.token
        await self.ws.send(json.dumps(env))
        return await asyncio.wait_for(fut, timeout)

    async def subscribe(self, port_id):
        cid = "sub-" + uuid.uuid4().hex[:6]
        fut = asyncio.get_event_loop().create_future()
        self.pending[cid] = fut   # resolves only if the subscription is REFUSED
        env = {"type": "call", "call_id": cid, "sender_id": self.me,
               "method": "port.subscribe", "args": {"id": port_id}}
        if self.per_call:
            env["credential"] = self.client.token
        await self.ws.send(json.dumps(env))
        return fut
