#!/usr/bin/env bash
# Original synthetic test pattern and sine waves; no downloaded/copyrighted media.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p hls
ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=size=160x90:rate=24 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 12 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -preset veryslow -crf 32 -g 48 -keyint_min 48 -sc_threshold 0 -c:a aac -b:a 48k -movflags +faststart progressive.mp4
ffmpeg -y -hide_banner -loglevel error -i progressive.mp4 -c copy -hls_time 2 -hls_playlist_type vod -hls_segment_filename hls/segment-%02d.ts hls/index.m3u8
ffmpeg -y -hide_banner -loglevel error -f lavfi -i sine=frequency=660:sample_rate=44100 -t 12 -c:a aac -b:a 48k -hls_time 2 -hls_playlist_type vod -hls_segment_filename hls/audio-%02d.ts hls/audio.m3u8
# master/subtitle playlists and VTT are hand-authored original fixtures, preserved here.
