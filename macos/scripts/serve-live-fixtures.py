#!/usr/bin/env python3
"""Local-only recording fixtures; no user accounts or external stream access."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import argparse
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=18709)
args = parser.parse_args()
cache = root / '.build/recording-fixtures'
cache.mkdir(parents=True, exist_ok=True)
slow = cache / 'slow.ts'
if not slow.exists():
    subprocess.run([str(root/'Resources/LiveTools/bin/ffmpeg'), '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=s=640x360:r=24:d=45', '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-b:v', '1000000',
                    '-g', '24', '-an', '-f', 'mpegts', '-n', str(slow)], check=True)
files = {'/slow.ts': slow, '/connecting.ts': slow, '/silent-stop.mkv': root/'Fixtures/silent-stop.mkv', '/clip-ja.mp4': root/'Fixtures/clip-ja.mp4'}
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = files.get(self.path)
        if path is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(path.stat().st_size))
        self.send_header('Content-Type', 'video/mp2t' if path.suffix == '.ts' else 'application/octet-stream')
        self.end_headers()
        try:
            if self.path == '/connecting.ts':
                time.sleep(12)  # HTTP connected, but no video packets yet.
            with path.open('rb') as stream:
                while chunk := stream.read(16384):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if self.path in ['/slow.ts', '/connecting.ts']:
                        time.sleep(.12)
        except (BrokenPipeError, ConnectionResetError):
            pass
print(f'Fixtures: http://127.0.0.1:{args.port}', flush=True)
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
