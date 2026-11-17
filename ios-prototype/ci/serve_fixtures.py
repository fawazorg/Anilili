"""Loopback-only, range-capable server for the original test media."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import io
import json
import threading
import time
from http.cookies import SimpleCookie
from urllib.parse import urlsplit, parse_qs


class FixtureHandler(SimpleHTTPRequestHandler):
    # Original controlled-fixture credentials; never log raw Cookie, Authorization or header values.
    expected_user_agent = "AnililiFixture/1.0"
    audit_lock = threading.Lock()
    audit = []
    attempts = {}

    @classmethod
    def reset_audit(cls):
        with cls.audit_lock:
            cls.audit.clear()
            cls.attempts.clear()

    def log_request(self, code="-", size="-"):
        # Diagnostics identify the route without retaining query credentials or request headers.
        self.log_message('"%s %s %s" %s %s', self.command,
                         urlsplit(self.path).path, self.request_version, str(code), str(size))

    def provider_reply(self, status, body, content_type="application/json", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.remaining = len(data)
        return io.BytesIO(data)

    def provider_route(self, path, query):
        if path == "/provider/requests":
            with self.audit_lock:
                if parse_qs(query).get("clear") == ["1"]:
                    self.audit.clear()
                    self.attempts.clear()
                events = list(self.audit)
            return self.provider_reply(200, events)
        cookies = SimpleCookie()
        try:
            cookies.load(self.headers.get("Cookie", ""))
        except Exception:
            pass
        cookie_matches = "fixture_session" in cookies and cookies["fixture_session"].value == "authorized"
        ua_matches = self.headers.get("User-Agent") == self.expected_user_agent
        with self.audit_lock:
            self.audit.append(dict(path=path, method=self.command,
                                   userAgentMatched=ua_matches, cookieMatched=cookie_matches,
                                   authorizationPresent=bool(self.headers.get("Authorization")),
                                   customHeaderPresent=bool(self.headers.get("X-Fixture-Secret")),
                                   refererPresent=bool(self.headers.get("Referer")),
                                   rangeRequested=self.headers.get("Range") is not None))
            self.attempts[path] = self.attempts.get(path, 0) + 1
            attempt = self.attempts[path]
        origin = f"http://127.0.0.1:{self.server.server_port}"
        if path.startswith("/provider/gated/"):
            if not cookie_matches or not ua_matches:
                return self.provider_reply(403, {"error": "Fixture media requires its synthetic cookie and user agent"})
            relative = path.removeprefix("/provider/gated/")
            self.path = "/provider/" + relative
            return None  # The existing range-capable file path serves original encrypted media.
        if path.startswith("/provider/status/"):
            try:
                status = int(path.rsplit("/", 1)[1])
            except ValueError:
                status = 400
            if status not in (401, 403, 404, 429, 500, 503):
                status = 400
            return self.provider_reply(status, {"error": "Controlled HTTP failure"},
                                       headers={"Retry-After": "0"} if status == 429 else {})
        if path == "/provider/timeout":
            try:
                seconds = min(3, max(0, float(parse_qs(query).get("seconds", ["2"])[0])))
            except ValueError:
                seconds = 2
            time.sleep(seconds)
            return self.provider_reply(200, {"link": origin + "/progressive.mp4", "format": "MP4"})
        if path.startswith("/provider/redirect/"):
            try:
                remaining = int(path.rsplit("/", 1)[1])
            except ValueError:
                remaining = 0
            if remaining not in (1, 2):
                return self.provider_reply(400, {})
            destination = "/provider/redirect/1" if remaining == 2 else "/provider/anidb/hls"
            return self.provider_reply(302, {}, headers={"Location": origin + destination})
        if path == "/provider/redirect-cross-origin":
            return self.provider_reply(302, {}, headers={"Location": f"http://localhost:{self.server.server_port}/provider/anidb/hls"})
        if path == "/provider/flaky":
            if attempt == 1:
                return self.provider_reply(503, {"error": "Controlled transient failure"})
            return self.provider_reply(200, {"link": origin + "/hls/master.m3u8"})
        if path.startswith("/provider/anidb/"):
            scenario = path.rsplit("/", 1)[1]
            if scenario == "malformed":
                return self.provider_reply(200, b"{malformed", content_type="application/json")
            if scenario == "missing":
                return self.provider_reply(200, {})
            link = origin + ("/progressive.mp4" if scenario == "mp4" else "/hls/master.m3u8")
            result = {"link": link, "format": "MP4" if scenario == "mp4" else "HLS"}
            if scenario == "relative":
                result["link"] = "/hls/master.m3u8"
            elif scenario == "expired":
                result["expiresAtMs"] = 1
            elif scenario == "unsupported-headers":
                result["headers"] = {"Referer": "https://example.invalid/fixture"}
            elif scenario == "unsupported-policy":
                result["redirectPolicy"] = "SAME_ORIGIN"
            elif scenario == "unsupported":
                result["requirements"] = ["DRM"]
            elif scenario == "gated":
                result.update(link=origin + "/provider/gated/hls/master.m3u8",
                              headers={"User-Agent": self.expected_user_agent},
                              cookies=[dict(name="fixture_session", value="authorized", domain="127.0.0.1",
                                            path="/provider/gated", secure=False)],
                              redirectPolicy="SYSTEM")
            elif scenario not in ("hls", "mp4", "relative"):
                return self.provider_reply(404, {})
            return self.provider_reply(200, result)
        return self.provider_reply(404, {})

    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".ts": "video/mp2t",
                      ".m3u8": "application/vnd.apple.mpegurl", ".vtt": "text/vtt", ".mp4": "video/mp4"}

    def do_GET(self):
        try:
            super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation/deadline tests deliberately close the client before a response finishes.
            return

    def do_HEAD(self):
        try:
            super().do_HEAD()
        except (BrokenPipeError, ConnectionResetError):
            return

    def send_head(self):
        parsed = urlsplit(self.path)
        if parsed.path.startswith("/provider/"):
            response = self.provider_route(parsed.path, parsed.query)
            if response is not None:
                return response
        path = Path(self.translate_path(self.path))
        root = Path(self.directory).resolve()
        if not path.resolve().is_relative_to(root) or not path.is_file():
            self.send_error(404)
            return None
        size = path.stat().st_size
        start, end = 0, size - 1
        request_range = self.headers.get("Range")
        if request_range:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", request_range)
            if not match or not any(match.groups()):
                return self.invalid_range(size)
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            else:
                start = max(0, size - int(last))
            if start > end or start >= size:
                return self.invalid_range(size)
        stream = path.open("rb")
        stream.seek(start)
        self.remaining = end - start + 1
        self.send_response(206 if request_range else 200)
        self.send_header("Content-Type", self.guess_type(str(path)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(self.remaining))
        if request_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        return stream

    def invalid_range(self, size):
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{size}")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return None

    def copyfile(self, source, outputfile):
        while self.remaining > 0:
            chunk = source.read(min(65536, self.remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            self.remaining -= len(chunk)


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1] / "Fixtures"
    ThreadingHTTPServer(("127.0.0.1", 8765), partial(FixtureHandler, directory=str(root))).serve_forever()
