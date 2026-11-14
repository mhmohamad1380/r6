"""Stands in for other servers by forwarding to a real one with one difference.
  legacy: from before /v1/known and /v1/parsed existed (404 on both; /health does not mention parsed)
  old:    demands a newer reader: /v1/parsed answers 426 like the real server does
  strict: refuses the data: /v1/parsed answers 422"""
import json
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, TARGET, MODE = int(sys.argv[1]), sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "legacy")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _go(self):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        if MODE == "legacy" and path in ("/v1/known", "/v1/parsed"):
            return self._reply(404)
        if MODE in ("old", "strict") and path == "/v1/known":
            return self._reply(200, b'{"known":[],"failed":[]}')   # so every replay looks new and reaches /v1/parsed
        if MODE == "old" and path == "/v1/parsed":
            return self._reply(426, json.dumps({"error": "parser_too_old", "message": "Please update your uploader: this server needs reader version 9.0.0 or newer, and yours is 1.2.0.", "minParser": "9.0.0"}).encode())
        if MODE == "strict" and path == "/v1/parsed":
            return self._reply(422, json.dumps({"error": "invalid_payload", "message": "The data did not pass validation: round.teams: must hold exactly 2 teams", "problems": ["round.teams: must hold exactly 2 teams"]}).encode())
        req = urllib.request.Request(TARGET + self.path, data=body, method=self.command, headers={k: v for k, v in self.headers.items() if k.lower() != "host"})
        try:
            r = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            r = e
        data = r.read()
        if MODE == "legacy" and path == "/health":
            d = json.loads(data)
            d.pop("parsed", None)
            data = json.dumps(d).encode()
        self._reply(r.status if hasattr(r, "status") else r.code, data)

    do_GET = do_POST = _go

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
