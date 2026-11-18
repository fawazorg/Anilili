"""Original provider-shaped HTTP fixtures; this does not contact upstream providers."""
import http.client
import json
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
from urllib.parse import urlencode, urlsplit, parse_qs
from serve_fixtures import FixtureHandler


class ExpandedProviderFixtureTests(unittest.TestCase):
    def setUp(self):
        FixtureHandler.reset_audit()
        root = Path(__file__).resolve().parents[1] / 'Fixtures'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(FixtureHandler, directory=str(root)))
        self.worker = threading.Thread(target=self.server.serve_forever)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()

    def request(self, path, method='GET', payload=None, cookie=None, ua=True):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        headers = {'User-Agent': 'Mozilla/5.0 OriginalFixture'} if ua else {}
        if cookie:
            headers['Cookie'] = cookie
        body = json.dumps(payload) if payload is not None else None
        if body:
            headers['Content-Type'] = 'application/json'
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_anipm_encoded_session_chain_and_both_media_formats(self):
        root = '/provider/expanded/anipm/'
        self.assertEqual(self.request(root + 'api/anime/anipm-server/_packages', ua=False)[0], 403)
        status, _, body = self.request(root + 'api/anime/anipm-server/_packages?anilistId=101')
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)['episodes']['2']['dub'])
        for episode, kind in [(1, 'mp4'), (2, 'hls')]:
            _, _, body = self.request(root + 'api/anime/playback-bootstrap/anilist/101?ep=1&lang=sub')
            selection = json.loads(body)['settlarSelection']
            _, _, body = self.request(root + 'api/anime/settlar/session?' + urlencode(dict(selection=selection, provider='anipm', ep=episode)))
            token = parse_qs(urlsplit(json.loads(body)['embedUrl']).query)['t'][0]
            status, _, body = self.request(root + 'api/embed/session?' + urlencode(dict(t=token)))
            self.assertEqual(status, 200)
            media = json.loads(body)
            self.assertEqual(media['kind'], kind)
            self.assertEqual(self.request(urlsplit(media['source']).path)[0], 200)

    def test_anichan_cookie_is_required_and_image_mime_segments_are_original_ts(self):
        root = '/provider/expanded/anichan/'
        self.assertIsNone(json.loads(self.request(root + 'site-config')[2])['turnstileSiteKey'])
        self.assertEqual(self.request(root + 'api/watch/servers')[0], 401)
        self.assertEqual(self.request(root + 'api/watch/session', 'POST', {'token': 'not-authorized'})[0], 403)
        status, headers, _ = self.request(root + 'api/watch/session', 'POST', {'token': ''})
        self.assertEqual(status, 200)
        cookie = headers['Set-Cookie'].split(';')[0]
        status, _, body = self.request(root + 'api/watch/servers?anilistId=101&ep=1&category=sub', cookie=cookie)
        self.assertEqual(status, 200)
        path = root.rstrip('/') + json.loads(body)['servers'][0]['stream']
        self.assertIn(b'index.m3u8', self.request(path)[2])
        playlist = self.request(root + 'media/index.m3u8')[2].decode()
        segment = next(line for line in playlist.splitlines() if line.endswith('.ts.png'))
        status, headers, body = self.request(root + 'media/' + segment)
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'image/png')
        original = Path(__file__).resolve().parents[1] / 'Fixtures/hls' / segment.removesuffix('.png')
        self.assertEqual(body, original.read_bytes())
        self.assertEqual(body[0], 0x47)  # MPEG-TS sync byte, not an image.

    def test_both_provider_catalog_and_details_share_anilist_shape(self):
        for provider in ['anipm', 'anichan']:
            path = f'/provider/expanded/{provider}/catalog'
            page = json.loads(self.request(path, 'POST', {'query': 'query { Page { media { id } } }'})[2])
            detail = json.loads(self.request(path, 'POST', {'query': 'query { Media(id:101) { id } }'})[2])
            self.assertEqual(page['data']['Page']['media'][0]['id'], detail['data']['Media']['id'])
