#!/usr/bin/env python3
"""Loopback only: real HLS media, pre/mid-roll advertisements and failures."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import argparse, subprocess, time, threading
parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=18739);args=parser.parse_args()
root=Path(__file__).resolve().parents[1];cache=root/'.build/twitch-fixtures';cache.mkdir(parents=True,exist_ok=True)
if not (cache/'source.m3u8').exists():
 subprocess.run([str(root/'Resources/LiveTools/bin/ffmpeg'),'-v','error','-f','lavfi','-i','testsrc2=s=640x360:r=24:d=36','-f','lavfi','-i','sine=frequency=440:duration=36','-c:v','h264_videotoolbox','-allow_sw','1','-b:v','1000000','-g','48','-c:a','aac','-f','hls','-hls_time','2','-hls_list_size','0','-hls_segment_filename',str(cache/'segment%02d.ts'),str(cache/'source.m3u8')],check=True)
starts={};failed_once=set();lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  parts=self.path.split('/'); mode=parts[1]
  with lock:start=starts.setdefault(mode,time.monotonic())
  elapsed=time.monotonic()-start
  kind=mode.split("-")[0]
  if kind == 'flaky' and (self.path.endswith('live.m3u8') or self.path.endswith('segment02.ts')):
   with lock:
    first = self.path not in failed_once
    failed_once.add(self.path)
   if first:
    self.send_error(503);return
  if kind in ('outage', 'windowFirst') and self.path.endswith('segment03.ts'):
   self.send_error(503);return
  if self.path.endswith('.m3u8'):
   if kind == 'cycle' and elapsed >= 4:
    self.send_error(403);return
   last=0 if kind=='stale' else min(17,int(elapsed/2))
   if kind == 'cycle':last=16 if elapsed >= 1 else 0
   if kind == 'windowSecond':last=8
   lines=['#EXTM3U','#EXT-X-VERSION:3','#EXT-X-TARGETDURATION:2','#EXT-X-MEDIA-SEQUENCE:0']
   if kind in ('windowFirst', 'windowSecond'):
    lines[-1] = '#EXT-X-MEDIA-SEQUENCE:' + ('500' if kind == 'windowSecond' else '100')
    lines.append('#EXT-X-PROGRAM-DATE-TIME:2026-11-21T09:00:00Z')
   for n in range(last+1):
    ad=kind in ['allads','cancelads'] or (kind.startswith('recovery') and n in [0,1,6,7])
    if n in [2,6,8]:lines.append('#EXT-X-DISCONTINUITY')
    lines.extend(['#EXTINF:2,'+('Amazon|fixture' if ad else 'live'),'ad.ts' if ad else ('broken.ts' if kind=='failure' else f'segment{n:02d}.ts')])
   if kind=='windowSecond' or last==17 or (kind=='flaky' and last>=4):lines.append('#EXT-X-ENDLIST')
   data=('\n'.join(lines)+'\n').encode()
  elif parts[-1] in ['ad.ts','broken.ts']:
   self.send_error(403);return # A successful recovery proves advert bytes were never fetched.
  else:
   path=cache/parts[-1]
   if not path.is_file():self.send_error(404);return
   data=path.read_bytes()
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers()
  try:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
print(f'Twitch fixtures: http://127.0.0.1:{args.port}',flush=True)
ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
