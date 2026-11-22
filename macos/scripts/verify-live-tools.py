#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path(__file__).resolve().parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
if len(sys.argv)>1 and sys.argv[1]=='--record-bundle':
    app=Path(sys.argv[2]);path=app/'Contents/Resources/LiveTools/manifest.json';manifest=json.loads(path.read_text())
    for item in manifest['components']:
        item['bundledSHA256']=sha(app/'Contents/Helpers/LiveTools'/item['file'])
    path.write_text(json.dumps(manifest,indent=2)+'\n')
else:
    path=root/'Resources/LiveTools/manifest.json'
    if not path.exists():sys.exit('Run python3 scripts/prepare-live-tools.py first')
    manifest=json.loads(path.read_text())
    for item in manifest['components']:
        path=root/'Resources/LiveTools/bin'/item['file']
        if not path.exists() or sha(path)!=item['sha256']:sys.exit('Missing/modified helper: '+item['file']+'. Run scripts/prepare-live-tools.py')
    ffmpeg=subprocess.check_output([str(root/'Resources/LiveTools/bin/ffmpeg'),'-version'],stderr=subprocess.STDOUT).decode()
    if '--enable-nonfree' in ffmpeg or '--enable-gpl' in ffmpeg:sys.exit('Expected redistributable LGPL-only FFmpeg')
    source=root/'Resources/LiveTools/Source/ffmpeg-n8.0.tar.gz'
    if not source.exists() or sha(source)!='dd4030dbfdc34d9ff255a116bdd1caade42500ac2981efa27f8b151cc54c7b9e':sys.exit('FFmpeg corresponding source missing')
    print('Verified pinned live helper hashes and FFmpeg source')
