"""Transfer interruption and per-test origin isolation for actual offline-player tests."""
from functools import partial
import http.client
from http.server import ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
import uuid
from serve_fixtures import FixtureHandler


class OfflineFixtureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1] / 'Fixtures'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(FixtureHandler, directory=str(self.root)))
        self.worker = threading.Thread(target=self.server.serve_forever)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()

    def request(self, path, method='GET', body=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_slow_transfer_preserves_range_bytes_and_resume_validators(self):
        status, headers, body = self.request('/provider/offline/slow.mp4', headers={'Range': 'bytes=2048-4095'})
        self.assertEqual(status, 206)
        self.assertEqual(body, (self.root / 'progressive.mp4').read_bytes()[2048:4096])
        self.assertEqual(headers['Accept-Ranges'], 'bytes')
        self.assertIn('ETag', headers)
        self.assertIn('Last-Modified', headers)

    def test_download_cookie_and_user_agent_are_enforced_on_actual_requests(self):
        path = '/provider/offline/gated.mp4'
        self.assertEqual(self.request(path)[0], 403)
        self.assertEqual(self.request(path, headers={'User-Agent': 'AnililiFixture/1.0'})[0], 403)
        status, _, body = self.request(path, headers={'User-Agent': 'AnililiFixture/1.0',
            'Cookie': 'fixture_session=authorized', 'Range': 'bytes=0-2047'})
        self.assertEqual(status, 206)
        self.assertEqual(body, (self.root / 'progressive.mp4').read_bytes()[:2048])
        self.assertEqual(self.request(path, headers={'User-Agent': 'AnililiFixture/1.0',
            'Cookie': 'fixture_session=changed-cookie'})[0], 403)

    def test_truncated_response_fails_complete_read_instead_of_becoming_offline_media(self):
        with self.assertRaises(http.client.IncompleteRead) as result:
            self.request('/provider/offline/truncated.mp4')
        self.assertEqual(len(result.exception.partial), 4096)
        status, _, body = self.request('/provider/offline/invalid.mp4')
        self.assertEqual(status, 200)
        self.assertNotEqual(body[4:8], b'ftyp')

    def test_origin_disabled_after_download_does_not_disable_unrelated_tests(self):
        prefix = '/provider/offline/isolated/' + str(uuid.uuid4())
        self.assertEqual(self.request(prefix + '/media.mp4')[0], 200)
        self.assertEqual(self.request(prefix + '/hls/master.m3u8')[0], 200)
        self.assertEqual(self.request(prefix + '/hls/index.m3u8')[0], 200)
        self.assertEqual(self.request(prefix + '/disable', 'POST', '{}')[0], 200)
        for media in ['/media.mp4', '/hls/master.m3u8', '/hls/index.m3u8', '/hls/segment-00.ts']:
            self.assertEqual(self.request(prefix + media)[0], 503)
        self.assertEqual(self.request('/hls/master.m3u8')[0], 200)
        unrelated = '/provider/offline/isolated/' + str(uuid.uuid4())
        self.assertEqual(self.request(unrelated + '/media.mp4')[0], 200)
