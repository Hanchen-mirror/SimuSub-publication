#!/usr/bin/env python3
"""Acquire pinned helpers; FFmpeg is built locally from unmodified upstream source."""
from pathlib import Path
import hashlib, json, subprocess, zipfile
ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'Resources/LiveTools'
CACHE = ROOT / '.build/live-downloads'
SPECS = [
    ('yt-dlp', '2026.10.21', 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.21/yt-dlp_macos', '7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40'),
    ('deno', '2.9.8', 'https://github.com/denoland/deno/releases/download/v2.9.8/deno-aarch64-apple-darwin.zip', '9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e'),
]
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    (DEST / 'bin').mkdir(parents=True, exist_ok=True)
    components=[]
    for name, version, url, digest in SPECS:
        archive=CACHE / url.rsplit('/', 1)[1]
        if not archive.exists() or sha(archive) != digest:
            subprocess.run(['curl','--fail','--location','--retry','3',url,'-o',str(archive)],check=True)
        if sha(archive) != digest: raise SystemExit('Hash mismatch: ' + name)
        data = zipfile.ZipFile(archive).read('deno') if name == 'deno' else archive.read_bytes()
        target=DEST/'bin'/name;target.write_bytes(data);target.chmod(0o755)
        components.append(dict(file=name,version=version,source=url,downloadSHA256=digest,sha256=sha(target),bytes=target.stat().st_size))
    subprocess.run([str(ROOT/'scripts/build-live-ffmpeg.sh')], check=True)
    for tool in ['ffmpeg', 'ffprobe']:
        binary=DEST/'bin'/tool
        components.append(dict(file=tool,version='8.0-simusub-clips-lgpl',source='https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.0',downloadSHA256='dd4030dbfdc34d9ff255a116bdd1caade42500ac2981efa27f8b151cc54c7b9e',sha256=sha(binary),bytes=binary.stat().st_size,license='LGPL-2.1-or-later',buildScript='scripts/build-live-ffmpeg.sh',correspondingSource='Source/ffmpeg-n8.0.tar.gz'))
    (DEST/'manifest.json').write_text(json.dumps(dict(components=components,policy='Pinned components; FFmpeg source and build recipe included. No executable auto-update.'),indent=2)+'\n')
if __name__ == '__main__': prepare()
