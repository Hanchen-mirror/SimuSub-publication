#!/usr/bin/env python3
"""Run offline checks on a signed macOS package and verify its actual reports."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("corpus", type=Path)
parser.add_argument("output", type=Path, help="New evidence directory")
args = parser.parse_args()
app = args.app.resolve(strict=True)
binary = app / "Contents/MacOS/SimulSubtitleMac"
fixture = Path(__file__).resolve().parents[1] / "Fixtures/clip-ja.mp4"
models = app / "Contents/SharedSupport/Models"
if not models.is_dir():
    models = Path.home() / "Library/Application Support/SimulSubtitle/models"
model = models / "mt/index-translate-2b.gguf"
checksum = "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a"


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as src:
        for block in iter(lambda: src.read(4 * 1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


if model.stat().st_size != 1312164352 or digest(model) != checksum:
    raise SystemExit("Installed translation model failed verification")
corpus = args.corpus.resolve(strict=True)
audio = json.loads(corpus.read_text())["audio"][:6]
if len(audio) != 6 or not all(Path(sample["path"]).is_file() for sample in audio):
    raise SystemExit("Six readable local audio samples are required")
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
summary = dict(version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"],
               executableSHA256=digest(binary), translationSHA256=checksum, suites={})
commands = {
    "signature": ["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
    "self-test": [binary, "--self-test"],
    "clips": [binary, "--clip-check", out / "clips", fixture, "--clip-real-models", models],
    "design": [binary, "--release-148-check", out / "design", models, corpus, "--design-fixture", fixture],
}
for name, command in commands.items():
    with (out / (name + ".log")).open("w") as log:
        subprocess.run(command, check=True, timeout=900, stdout=log, stderr=subprocess.STDOUT)
    if name in {"clips", "design"}:
        report = json.loads((out / name / "report.json").read_text())
        if report.get("passed") is not True or not report.get("checks"):
            raise SystemExit(f"{name}: {report.get('error', 'invalid report')}")
        summary["suites"][name] = len(report["checks"])
captions = json.loads((out / "clips/local-asr-captions.json").read_text())
if not any(cue.get("original") and cue.get("translated") for cue in captions):
    raise SystemExit("Real-model clip produced no bilingual captions")
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary))
