import http.server, socketserver, json, time

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        b = self.rfile.read(n).decode()
        open('/tmp/mods-spike/events.jsonl', 'a').write(json.dumps({"recv": time.time() * 1000, "body": json.loads(b)}) + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')

    def log_message(self, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", 8899), H).serve_forever()
