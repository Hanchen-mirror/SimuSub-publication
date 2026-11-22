#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ "$(uname -m)" != "arm64" ]; then
  printf 'This app supports Apple Silicon only.\n' >&2
  exit 1
fi
SDK_PATH="${MACOS_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK_PATH" ]; then SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"; fi
CACHE_PATH="$PWD/.build/swiftpm-cache"
MODULE_CACHE="$PWD/.build/module-cache-v122"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SIMUSUB_BUILD_MODE="${SIMUSUB_BUILD_MODE:-standard}"
case "$SIMUSUB_BUILD_MODE" in
  standard) ;;
  local-candidate)
    if [ "$#" -ne 1 ]; then
      printf 'Local candidates require an explicit output path.\n' >&2
      exit 1
    fi
    ;;
  *) printf 'Unknown build mode: %s\n' "$SIMUSUB_BUILD_MODE" >&2; exit 1 ;;
esac
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(python3 - "$SIMUSUB_BUILD_MODE" <<'PY'
import json, pathlib, re, subprocess, sys
metadata = pathlib.Path.home() / 'Library/Application Support/SimuSub Development Signing/identity.json'
if sys.argv[1] == 'local-candidate' and metadata.exists():
    # Pin an established channel, even if another certificate appears later.
    # Changing identity requires an explicit CODE_SIGN_IDENTITY migration.
    value = json.loads(metadata.read_text())['sha1']
    if not re.fullmatch(r'[0-9A-F]{40}', value):
        raise SystemExit('Invalid local signing fingerprint')
    print(value)
else:
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    apple = re.search(r'([0-9A-F]{40}) "Apple Development:', identities)
    if apple:
        print(apple[1])
PY
)"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  printf 'No stable signing identity. Set CODE_SIGN_IDENTITY; do not silently replace an authorized app with an ad hoc build.\n' >&2
  exit 1
fi
if [ "$SIGNING_IDENTITY" = "-" ] && [ "${SIMUSUB_ALLOW_ADHOC:-0}" != "1" ]; then
  printf 'Ad hoc signing is restricted to explicit experiments: SIMUSUB_ALLOW_ADHOC=1. Do not install these over an authorized build.\n' >&2
  exit 1
fi
# Keep the local review channel independent from the last standard release.
SIMUSUB_RELEASE_FIELDS="$(python3 - "$SIMUSUB_BUILD_MODE" <<'PYTHON'
import json
import os
import plistlib
import re
import sys

if sys.argv[1] == 'local-candidate':
    with open('local-candidate-version.json') as stream:
        record = json.load(stream)
    previous, previous_build = record['version'], record['build']
else:
    with open('Resources/Info.plist', 'rb') as stream:
        info = plistlib.load(stream)
    previous, previous_build = info['CFBundleShortVersionString'], int(info['CFBundleVersion'])

def fields(value):
    if not re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}', value):
        raise SystemExit('Expected a three-part version, e.g. 1.6.1')
    return tuple(map(int, value.split('.')))

if re.fullmatch(r'1\.[0-9]{2}', previous):
    minimum = next_version = (1, 6, 1)
else:
    minimum = fields(previous)
    major, minor, patch = minimum
    next_version = (major, minor, patch + 1)
version = os.environ.get('SIMUSUB_VERSION_OVERRIDE', '.'.join(map(str, next_version)))
if fields(version) < minimum:
    raise SystemExit('Version override precedes the last version of this channel')
build = os.environ.get('SIMUSUB_BUILD_NUMBER_OVERRIDE', str(previous_build + 1))
if not re.fullmatch('[1-9][0-9]*', build) or int(build) <= previous_build:
    raise SystemExit('Build number must increase within the same channel')
print(version, build)
PYTHON
)"
SIMUSUB_RELEASE_VERSION="${SIMUSUB_RELEASE_FIELDS% *}"
SIMUSUB_RELEASE_BUILD="${SIMUSUB_RELEASE_FIELDS##* }"
APP_PATH="${1:-../../../outputs/SimuSub v${SIMUSUB_RELEASE_VERSION}.app}"
case "$APP_PATH" in *.app) ;; *) printf 'Output must end in .app\n' >&2; exit 1 ;; esac
mkdir -p "$(dirname "$APP_PATH")"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
if [ "$SIMUSUB_BUILD_MODE" = local-candidate ] && { [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; }; then
  printf 'Local candidate output already exists: %s\n' "$APP_PATH" >&2
  exit 1
fi
python3 - "$APP_PATH" <<'PY'
import subprocess
import sys
prefix = sys.argv[1] + '/Contents/MacOS/SimulSubtitleMac'
commands = subprocess.run(['/bin/ps', '-axo', 'command='], capture_output=True, text=True, check=True).stdout.splitlines()
if any(command.strip().startswith(prefix) for command in commands):
    sys.exit('The destination app is running. Quit it before replacing its signed bundle.')
PY
python3 scripts/verify-live-tools.py
python3 scripts/verify-theme-palettes.py
python3 scripts/verify-interface-strings.py
python3 scripts/verify-local-model-catalog.py
mkdir -p "$CACHE_PATH" "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build -c "$BUILD_CONFIGURATION" --arch arm64 --sdk "$SDK_PATH" --cache-path "$CACHE_PATH" --disable-sandbox
BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build -c "$BUILD_CONFIGURATION" --arch arm64 --sdk "$SDK_PATH" --cache-path "$CACHE_PATH" --disable-sandbox --show-bin-path)"
STAGING="$(mktemp -d "$PWD/.build/app-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/SimuSub.app"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$CONTENTS/Helpers"
cp "$BIN_PATH/SimulSubtitleMac" "$CONTENTS/MacOS/SimulSubtitleMac"
cp Resources/Info.plist "$CONTENTS/Info.plist"
python3 - "$CONTENTS/Info.plist" "$SIMUSUB_RELEASE_VERSION" "$SIMUSUB_RELEASE_BUILD" "$SIMUSUB_BUILD_MODE" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
info['CFBundleShortVersionString'] = sys.argv[2]
info['CFBundleVersion'] = sys.argv[3]
if sys.argv[4] == 'local-candidate':
    info['CFBundleIdentifier'] = 'com.mirror.simusub.localcandidate'
    # Keep the product name consistent in Finder and the macOS privacy prompt.
    info['CFBundleName'] = info['CFBundleDisplayName'] = 'SimuSub'
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(info, stream, sort_keys=False)
PY
cp ../LICENSE "$CONTENTS/Resources/LICENSE"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
cp Resources/SimuSubMark.png "$CONTENTS/Resources/SimuSubMark.png"
cp Resources/BrandCat.png "$CONTENTS/Resources/BrandCat.png"
cp Resources/LocalModelCatalog.json "$CONTENTS/Resources/LocalModelCatalog.json"
cp Resources/InterfaceStrings.json "$CONTENTS/Resources/InterfaceStrings.json"
cp Resources/ThemePalettes.json "$CONTENTS/Resources/ThemePalettes.json"
cp -R Resources/AudioModels "$CONTENTS/Resources/AudioModels"
cp -R Resources/MP3 "$CONTENTS/Resources/MP3"
cp Resources/MP3/libmp3lame.0.dylib "$CONTENTS/Frameworks/libmp3lame.0.dylib"
cp -R Resources/TextLayout "$CONTENTS/Resources/TextLayout"
cp -R Resources/BrandIcons "$CONTENTS/Resources/BrandIcons"
cp "$BIN_PATH/SimuSubRelaunch" "$CONTENTS/Helpers/SimuSubRelaunch"
cp "$BIN_PATH/SimuSubLiveTool" "$CONTENTS/Helpers/SimuSubLiveTool"
mkdir -p "$CONTENTS/Helpers/LiveTools" "$CONTENTS/Resources/LiveTools"
cp Resources/LiveTools/bin/* "$CONTENTS/Helpers/LiveTools/"
cp Resources/LiveTools/manifest.json "$CONTENTS/Resources/LiveTools/manifest.json"
cp -R Resources/LiveTools/Licenses "$CONTENTS/Resources/LiveTools/Licenses"
cp -R Resources/LiveTools/Source "$CONTENTS/Resources/LiveTools/Source"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp -R "$BIN_PATH/llama.framework" "$CONTENTS/Frameworks/llama.framework"
FRAMEWORK_BINARY="$CONTENTS/Frameworks/llama.framework/Versions/A/llama"
lipo "$FRAMEWORK_BINARY" -thin arm64 -output "$STAGING/llama-arm64"
mv "$STAGING/llama-arm64" "$FRAMEWORK_BINARY"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/SimulSubtitleMac"
codesign --force --sign "$SIGNING_IDENTITY" "$CONTENTS/Frameworks/llama.framework"
codesign --force --sign "$SIGNING_IDENTITY" "$CONTENTS/Frameworks/libmp3lame.0.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$CONTENTS/Helpers/SimuSubRelaunch"
codesign --force --sign "$SIGNING_IDENTITY" "$CONTENTS/Helpers/SimuSubLiveTool"
for LIVE_HELPER in "$CONTENTS"/Helpers/LiveTools/*; do
  codesign --force --sign "$SIGNING_IDENTITY" "$LIVE_HELPER"
done
python3 scripts/verify-live-tools.py --record-bundle "$STAGED_APP"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements Resources/Audio.entitlements "$STAGED_APP"
  printf 'Local build: authorize this exact bundle once. Rebuilding changes its ad-hoc identity.\n'
elif [ "$SIMUSUB_BUILD_MODE" = local-candidate ]; then
  # Local certificates provide a fixed DR without changing system trust policy.
  # This is a local test channel, not Developer ID distribution or notarization.
  codesign --force --timestamp=none --entitlements Resources/Audio.entitlements --sign "$SIGNING_IDENTITY" "$STAGED_APP"
else
  codesign --force --options runtime --entitlements Resources/Audio.entitlements --sign "$SIGNING_IDENTITY" "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
mkdir -p "$(dirname "$APP_PATH")"
if [ "$SIMUSUB_BUILD_MODE" = local-candidate ]; then
  python3 - "$STAGED_APP" "$APP_PATH" <<'PY'
import os
import sys
if os.path.lexists(sys.argv[2]):
    raise SystemExit('Local candidate output already exists')
os.rename(sys.argv[1], sys.argv[2])
PY
  python3 - "$SIMUSUB_RELEASE_VERSION" "$SIMUSUB_RELEASE_BUILD" <<'PYTHON'
import json
import os
import sys
from pathlib import Path

path = Path('local-candidate-version.json')
temporary = path.with_suffix('.json.tmp')
temporary.write_text(json.dumps(dict(version=sys.argv[1], build=int(sys.argv[2]))) + chr(10))
os.replace(temporary, path)
PYTHON
  printf 'Built and verified local candidate: %s\n' "$APP_PATH"
  exit 0
fi
if [ -d "$APP_PATH" ]; then rm -rf "$APP_PATH"; fi
mv "$STAGED_APP" "$APP_PATH"
python3 - "$SIMUSUB_RELEASE_VERSION" "$SIMUSUB_RELEASE_BUILD" <<'PY'
import os
from pathlib import Path
import re
import sys
path = Path('Resources/Info.plist')
source = path.read_text()
for key, value in [('CFBundleShortVersionString', sys.argv[1]), ('CFBundleVersion', sys.argv[2])]:
    source, count = re.subn(r'(<key>' + key + r'</key>\s*<string>)[^<]*(</string>)',
                            lambda match: match[1] + value + match[2], source)
    if count != 1:
        raise SystemExit(f'Cannot record successful release: {key}')
temporary = path.with_suffix('.plist.tmp')
temporary.write_text(source)
os.replace(temporary, path)
PY
printf 'Built and verified: %s\n' "$APP_PATH"
