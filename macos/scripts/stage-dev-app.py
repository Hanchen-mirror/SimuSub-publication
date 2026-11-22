#!/usr/bin/env python3
"""Stage the latest compiled executable in a previous release for isolated QA.

Does not increment release versions. All diagnostic switches isolate account data.
"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--version", default="1.09")
args = parser.parse_args()
mac = Path(__file__).resolve().parents[1]
app = args.output.resolve()
if app.exists():
    raise SystemExit("Choose an unused development bundle path")
shutil.copytree(args.base, app, symlinks=True)
contents = app / "Contents"
bins = mac / ".build/out/Products/Release"
for binary, destination in [("SimulSubtitleMac", "MacOS"), ("SimuSubLiveTool", "Helpers"), ("SimuSubRelaunch", "Helpers")]:
    shutil.copy2(bins / binary, contents / destination / binary)
shutil.copy2(mac / "Resources/LocalModelCatalog.json", contents / "Resources/LocalModelCatalog.json")
shutil.copy2(mac / "Resources/InterfaceStrings.json", contents / "Resources/InterfaceStrings.json")
shutil.copy2(mac / "Resources/ThemePalettes.json", contents / "Resources/ThemePalettes.json")
shutil.copytree(mac / "Resources/BrandIcons", contents / "Resources/BrandIcons", dirs_exist_ok=True)
shutil.copytree(mac / "Resources/LiveTools/bin", contents / "Helpers/LiveTools", dirs_exist_ok=True)
shutil.copy2(mac / "Resources/LiveTools/manifest.json", contents / "Resources/LiveTools/manifest.json")
shutil.copytree(mac / "Resources/MP3", contents / "Resources/MP3", dirs_exist_ok=True)
shutil.copy2(mac / "Resources/MP3/libmp3lame.0.dylib", contents / "Frameworks/libmp3lame.0.dylib")
subprocess.run(["codesign", "--force", "--sign", "-", str(contents / "Frameworks/libmp3lame.0.dylib")], check=True)
for helper in (contents / "Helpers/LiveTools").iterdir():
    subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True)
subprocess.run(["python3", str(mac / "scripts/verify-live-tools.py"), "--record-bundle", str(app)], check=True)
info = plistlib.loads((mac / "Resources/Info.plist").read_bytes())
identifier = args.version.replace(".", "") + hashlib.sha256(str(app).encode()).hexdigest()[:8]
info.update(CFBundleIdentifier="com.mirror.simusub.checks" + identifier, CFBundleName="SimuSub " + identifier + " Checks",
            CFBundleDisplayName="SimuSub " + identifier + " Checks", CFBundleShortVersionString=args.version + "-dev")
(contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(contents / "MacOS/SimulSubtitleMac")], check=True)
for binary in [contents / "Helpers/SimuSubLiveTool", contents / "Helpers/SimuSubRelaunch"]:
    subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
