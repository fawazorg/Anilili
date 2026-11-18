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
        if path.startswith("/provider/expanded/"):
            return self.expanded_route(path, parse_qs(query), origin)
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

    def expanded_route(self, path, query, origin):
        """Original provider-shaped metadata; session values are synthetic and local only."""
        prefix = "/provider/expanded/"
        provider, _, route = path.removeprefix(prefix).partition("/")
        base = origin + prefix + provider
        if provider not in ("anipm", "anichan"):
            return self.provider_reply(404, {})
        if route != "catalog" and not route.startswith("media/") and not self.headers.get("User-Agent", "").startswith("Mozilla/"):
            return self.provider_reply(403, {"error": "Fixture requires provider User-Agent"})
        if route == "catalog":
            # The existing AniList parser owns catalog/details; this is only its raw HTTP fixture.
            request = getattr(self, "json_body", {})
            media = dict(id=101, title={"english": "Original Provider Fixture"},
                         description="Original deterministic provider journey", episodes=2)
            body = {"Media": media} if "Media(" in request.get("query", "") else {"Page": {"media": [media]}}
            return self.provider_reply(200, {"data": body})
        if provider == "anipm":
            if route == "api/anime/anipm-server/_packages":
                return self.provider_reply(200, {"episodes": {"1": {"sub": True, "dub": True},
                                                             "2": {"sub": True, "dub": False}}})
            if route.startswith("api/anime/playback-bootstrap/anilist/"):
                return self.provider_reply(200, {"effectiveLanguage": query.get("lang", ["sub"])[0],
                                                "settlarSelection": "original & selection"})
            if route == "api/anime/settlar/session":
                valid = query.get("selection") == ["original & selection"] and query.get("provider") == ["anipm"]
                if not valid:
                    return self.provider_reply(400, {})
                episode = query.get("ep", ["1"])[0]
                return self.provider_reply(200, {"embedUrl": base + "/embed?t=original%26token%3D" + episode})
            if route == "api/embed/session":
                token = query.get("t", [""])[0]
                if token not in ("original&token=1", "original&token=2"):
                    return self.provider_reply(403, {})
                progressive = token.endswith("1")
                subtitles = [] if progressive else [{"url": "https://example.invalid/original.vtt", "srclang": "en", "label": "Original external captions"}]
                return self.provider_reply(200, {"source": origin + ("/progressive.mp4" if progressive else "/hls/master.m3u8"),
                                                "kind": "mp4" if progressive else "hls", "subtitles": subtitles})
        else:
            if route == "site-config":
                return self.provider_reply(200, {"turnstileSiteKey": None})
            if route == "api/watch/episodes":
                return self.provider_reply(200, {"episodes": 2, "dubAvailable": True})
            if route == "api/watch/session" and self.command == "POST":
                if getattr(self, "json_body", None) != {"token": ""}:
                    return self.provider_reply(403, {})
                return self.provider_reply(200, {"exp": int(time.time()) + 7200},
                    headers={"Set-Cookie": "anichan_ws=original-session; Path=/; HttpOnly; SameSite=Lax"})
            if route == "api/watch/servers":
                valid = self.headers.get("Cookie") == "anichan_ws=original-session"
                with self.audit_lock:
                    self.audit[-1]["providerSessionMatched"] = valid
                if not valid:
                    return self.provider_reply(401, {"detail": "session"})
                subtitles = [{"url": "https://example.invalid/original.vtt", "lang": "English"}] if query.get("ep") == ["2"] else []
                return self.provider_reply(200, {"servers": [{"name": "anichan", "label": "★ AniChan",
                    "rank": 1, "stream": "/media/master.m3u8", "subtitles": subtitles}]})
            if route.startswith("media/"):
                relative = route.removeprefix("media/")
                if relative in ("master.m3u8", "index.m3u8", "audio.m3u8", "subtitles.m3u8"):
                    contents = (Path(self.directory) / "hls" / relative).read_text()
                    # Exercise AniChan's image-extension/MIME MPEG-TS delivery explicitly.
                    contents = re.sub(r"(?m)^([^#\n]+\.ts)$", r"\1.png", contents)
                    return self.provider_reply(200, contents.encode(), "application/vnd.apple.mpegurl")
                if re.fullmatch(r"(?:segment|audio)-\d{2}\.ts\.png", relative):
                    media = Path(self.directory) / "hls" / relative.removesuffix(".png")
                    if media.is_file():
                        return self.provider_reply(200, media.read_bytes(), "image/png")
                if relative == "subtitles.vtt":
                    return self.provider_reply(200, (Path(self.directory) / "hls" / relative).read_bytes(), "text/vtt")
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

    def do_POST(self):
        if not urlsplit(self.path).path.startswith("/provider/expanded/"):
            self.send_error(405)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 <= size <= 65536:
                self.send_error(413)
                return
            self.json_body = json.loads(self.rfile.read(size))
            if not isinstance(self.json_body, dict):
                self.send_error(400)
                return
            source = self.send_head()
            if source:
                with source:
                    self.copyfile(source, self.wfile)
        except (ValueError, TypeError):
            self.send_error(400)
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
