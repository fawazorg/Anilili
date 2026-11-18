"""Regenerate original AES-128 test media; this is not DRM or a provider key."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
hls = root / "hls"
hls.mkdir(exist_ok=True)
key = hls / "key.bin"
key.write_bytes(bytes.fromhex("00112233445566778899aabbccddeeff"))
with tempfile.TemporaryDirectory(prefix="anilili-original-key-") as temp:
    info = Path(temp) / "key-info.txt"
    info.write_text(f"key.bin\n{key}\n0123456789abcdef0123456789abcdef\n")
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(root.parent / "progressive.mp4"),
                    "-c", "copy", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_key_info_file", str(info),
                    "-hls_segment_filename", str(hls / "segment-%02d.ts"), str(hls / "index.m3u8")], check=True)
(hls / "master.m3u8").write_text('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=160x90,CODECS="avc1.42c00c,mp4a.40.2"\nindex.m3u8\n')
