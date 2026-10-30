import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from uuid import UUID, uuid4


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        started = time.monotonic()
        try:
            self.request_id = str(UUID(self.headers.get("X-Correlation-ID", "")))
        except ValueError:
            self.request_id = str(uuid4())
        path = urlsplit(self.path).path
        region = os.environ["REGION"]
        if path in ("/health/live", "/health/ready"):
            status, body = 200, {"status": "ok", "region": region}
        elif path == "/":
            status, body = 200, {
                "service": "regional-demo",
                "message": "Private AKS through APIM and Front Door",
                "region": region,
            }
        else:
            status, body = 404, {"error": "not_found", "region": region}
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Correlation-ID", self.request_id)
        self.end_headers()
        self.wfile.write(payload)
        print(json.dumps({
            "event": "request",
            "request_id": self.request_id,
            "region": region,
            "method": self.command,
            "path": path,
            "status": status,
            "duration_ms": round((time.monotonic() - started) * 1000, 3),
        }), flush=True)

    def log_request(self, code="-", size="-"):
        pass

    def log_message(self, format, *args):
        print(json.dumps({"event": "http_error", "message": format % args}), flush=True)


if __name__ == "__main__":
    if not os.environ.get("REGION"):
        raise RuntimeError("REGION is required")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
