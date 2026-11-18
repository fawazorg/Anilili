import http.client
import json
import re
import socket
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from serve_fixtures import FixtureHandler


class FixtureServerTests(unittest.TestCase):
    def test_mime_types(self):
        for extension, mime in [(".ts", "video/mp2t"), (".m3u8", "application/vnd.apple.mpegurl"),
                                (".vtt", "text/vtt"), (".mp4", "video/mp4")]:
            self.assertEqual(FixtureHandler.extensions_map[extension], mime)

    def test_http_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            Path(temp, "media.mp4").write_bytes(b"0123456789")
            server = ThreadingHTTPServer(("127.0.0.1", 0), partial(FixtureHandler, directory=temp))
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                for method, path, headers, status, body in [
                    ("GET", "/media.mp4", {}, 200, b"0123456789"),
                    ("GET", "/media.mp4", {"Range": "bytes=2-4"}, 206, b"234"),
                    ("GET", "/media.mp4", {"Range": "bytes=-2"}, 206, b"89"),
                    ("HEAD", "/media.mp4", {}, 200, b""),
                    ("GET", "/media.mp4", {"Range": "bytes=20-"}, 416, b""),
                    ("GET", "/../missing", {}, 404, None),
                ]:
                    with self.subTest(method=method, path=path, headers=headers):
                        connection = http.client.HTTPConnection(*server.server_address)
                        connection.request(method, path, headers=headers)
                        response = connection.getresponse()
                        self.assertEqual(response.status, status)
                        if status in (200, 206):
                            self.assertEqual(response.getheader("Content-Type"), "video/mp4")
                        result = response.read()
                        if body is not None:
                            self.assertEqual(result, body)
                        connection.close()
            finally:
                server.shutdown()
                server.server_close()
                worker.join()


class ProviderFixtureTests(unittest.TestCase):
    def setUp(self):
        FixtureHandler.reset_audit()
        root = Path(__file__).resolve().parents[1] / "Fixtures"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(FixtureHandler, directory=str(root)))
        self.worker = threading.Thread(target=self.server.serve_forever)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()

    def request(self, path, headers=None, method="GET", timeout=3):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=timeout)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_provider_responses_redirect_chain_and_metadata(self):
        for scenario, media in [("mp4", "MP4"), ("hls", "HLS"), ("gated", "HLS")]:
            status, _, body = self.request("/provider/anidb/" + scenario)
            self.assertEqual(status, 200)
            decoded = json.loads(body)
            self.assertEqual(decoded["format"], media)
            self.assertTrue(decoded["link"].startswith("http://127.0.0.1:"))
        _, _, relative = self.request("/provider/anidb/relative")
        self.assertEqual(json.loads(relative)["link"], "/hls/master.m3u8")
        path = "/provider/redirect/2"
        for expected in (302, 302, 200):
            status, headers, body = self.request(path)
            self.assertEqual(status, expected)
            if status == 302:
                from urllib.parse import urlsplit
                path = urlsplit(headers["Location"]).path
        self.assertIn("link", json.loads(body))
        status, headers, _ = self.request("/provider/redirect-cross-origin", {
            "Authorization": "Bearer synthetic-fixture-only", "X-Fixture-Secret": "synthetic-fixture-only",
            "Referer": "https://example.invalid/fixture", "Cookie": "fixture_session=authorized"})
        self.assertEqual(status, 302)
        self.assertIn("//localhost:", headers["Location"])
        self.request("/provider/anidb/hls")
        _, _, raw_audit = self.request("/provider/requests")
        initial, destination = json.loads(raw_audit)[-2:]
        self.assertEqual(initial["method"], "GET")
        for key in ["authorizationPresent", "customHeaderPresent", "refererPresent", "cookieMatched"]:
            self.assertTrue(initial[key])
            self.assertFalse(destination[key])
        self.assertNotIn(b"synthetic-fixture-only", raw_audit)

    def test_failures_expiry_and_bounded_retry_fixture(self):
        for status in (401, 403, 404, 429, 500, 503):
            actual, headers, _ = self.request("/provider/status/" + str(status))
            self.assertEqual(actual, status)
            if status == 429:
                self.assertEqual(headers["Retry-After"], "0")
        _, _, expired = self.request("/provider/anidb/expired")
        self.assertEqual(json.loads(expired)["expiresAtMs"], 1)
        _, _, malformed = self.request("/provider/anidb/malformed")
        with self.assertRaises(json.JSONDecodeError):
            json.loads(malformed)
        self.assertEqual(self.request("/provider/flaky")[0], 503)
        self.assertEqual(self.request("/provider/flaky")[0], 200)

    def test_every_gated_playlist_segment_and_key_request_checks_cookie_and_user_agent(self):
        base = "/provider/gated/hls/"
        headers = {"User-Agent": "AnililiFixture/1.0", "Cookie": "fixture_session=authorized"}
        for path in ["master.m3u8", "index.m3u8", "segment-00.ts", "key.bin"]:
            self.assertEqual(self.request(base + path)[0], 403)
            self.assertEqual(self.request(base + path, {"User-Agent": headers["User-Agent"]})[0], 403)
            self.assertEqual(self.request(base + path, {"Cookie": headers["Cookie"]})[0], 403)
            status, _, body = self.request(base + path, headers)
            self.assertEqual(status, 200)
            if path == "key.bin":
                self.assertEqual(len(body), 16)
            elif path == "index.m3u8":
                self.assertIn(b'URI="key.bin"', body)
                self.assertIn(b"segment-00.ts", body)
        status, response_headers, body = self.request(base + "segment-00.ts", {**headers, "Range": "bytes=0-15"})
        self.assertEqual(status, 206)
        self.assertEqual(len(body), 16)
        self.assertTrue(response_headers["Content-Range"].startswith("bytes 0-15/"))
        _, _, raw = self.request("/provider/requests")
        events = json.loads(raw)
        successful = [e for e in events if e["cookieMatched"] and e["userAgentMatched"]]
        self.assertTrue(any(e["path"].endswith("key.bin") for e in successful))
        self.assertTrue(any(e["path"].endswith(".ts") and e["rangeRequested"] for e in successful))
        self.assertNotIn(b"authorized", raw)
        self.assertNotIn(b"AnililiFixture/1.0", raw)
        self.assertEqual(json.loads(self.request("/provider/requests?clear=1")[2]), [])

    def test_request_log_omits_query_credentials(self):
        from unittest.mock import patch
        messages = []
        def capture(_handler, template, *arguments):
            messages.append(template % arguments)
        with patch.object(FixtureHandler, "log_message", capture):
            status, _, _ = self.request("/provider/anidb/hls?token=original-test-only")
        self.assertEqual(status, 200)
        output = "\n".join(messages)
        self.assertIn("GET /provider/anidb/hls HTTP/1.1", output)
        self.assertNotIn("token", output)
        self.assertNotIn("original-test-only", output)

    def test_timeout_fixture_is_interruptible_by_client_deadline(self):
        with self.assertRaises((TimeoutError, socket.timeout)):
            self.request("/provider/timeout?seconds=0.3", timeout=0.05)


if __name__ == "__main__":
    unittest.main()
