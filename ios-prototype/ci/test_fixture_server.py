import http.client
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


if __name__ == "__main__":
    unittest.main()
