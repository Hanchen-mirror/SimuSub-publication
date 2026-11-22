#!/usr/bin/env python3
"""Build and verify SimuSub's offline installation image from local signed inputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from finder_layout import APP, DESTINATION, check_layout, set_layout

HERE = Path(__file__).resolve().parent
# Families shipped by this offline edition. Additional catalog entries are opt-in downloads.
OFFLINE_CATALOG_IDS = ("sensevoice", "whisper-base", "whisper-small", "qwen3-asr")


def run(*args):
    subprocess.run(args, check=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_file(path, entry):
    require(path.is_file() and not path.is_symlink(), f"Missing regular file: {path}")
    require(path.stat().st_size == entry["byteCount"], f"Unexpected file size: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 << 20), b""):
            digest.update(block)
    require(digest.hexdigest() == entry["sha256"], f"SHA-256 mismatch: {path}")


def release_files(app):
    files = json.loads((HERE / "core-models.json").read_text())
    catalog = json.loads((app / "Contents/Resources/LocalModelCatalog.json").read_text())
    catalog_by_id = {model["id"]: model for model in catalog}
    for family in OFFLINE_CATALOG_IDS:
        for member in catalog_by_id[family]["files"]:
            require(Path(member["name"]).name == member["name"], "Invalid catalog filename")
            files.append(dict(path=f"{family}/{member['name']}", byteCount=member["byteCount"],
                              sha256=member["sha256"], url=member["url"]))
    return sorted(files, key=lambda entry: entry["path"])


def models_from_volume(volume, image, files):
    disk = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", volume]))
    require(disk.get("MountPoint") == str(volume) and disk.get("BusProtocol") == "Disk Image"
            and disk.get("WritableVolume") is False, "Expected a read-only mounted disk image")
    images = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))["images"]
    backing = next(entry for entry in images if any(device.get("mount-point") == str(volume)
                   for device in entry["system-entities"]))
    source_image = image or backing["image-path"]
    run("/usr/bin/codesign", "--verify", "--strict", source_image)
    partitions = plistlib.loads(subprocess.check_output(
        ["/usr/bin/hdiutil", "imageinfo", "-plist", source_image]))["partitions"]["partitions"]
    require(disk.get("DiskUUID") and any(part.get("partition-UUID") == disk["DiskUUID"]
            for part in partitions), "Signed source image does not match the mounted partition")
    app = volume / APP
    support = app / "Contents/SharedSupport"
    if (support / "ModelManifest.json").is_file():
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
        manifest, models = support / "ModelManifest.json", support / "Models"
    else:
        # Earlier signed offline images placed the model payload next to their installer.
        installer = volume / "拖到这里安装.app"
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", installer)
        manifest = installer / "Contents/Resources/ModelManifest.json"
        require((volume / "ModelManifest.json").read_bytes() == manifest.read_bytes(),
                "Source disk manifest differs from its signed copy")
        models = volume / "Models"
    require(json.loads(manifest.read_bytes()) == {"schemaVersion": 1, "files": files},
            "Source model manifest differs from the release catalog")
    return models


def signing_certificate(app, prefix):
    run("/usr/bin/codesign", "-d", f"--extract-certificates={prefix}", app)
    return Path(str(prefix) + "0").read_bytes()


def make_stage(stage, app, models, identity, files, require_markers):
    bundled = stage / APP
    run("/usr/bin/ditto", "--noqtn", app, bundled)
    support = bundled / "Contents/SharedSupport"
    support.mkdir(exist_ok=True)
    payload = support / "Models"
    payload.mkdir()
    for entry in files:
        source = models / entry["path"]
        require(source.parent.resolve() == source.parent, f"Symlink in model directory: {source}")
        verify_file(source, entry)
        if require_markers:
            marker = Path(str(source) + ".sha256")
            require(marker.is_file() and not marker.is_symlink()
                    and marker.read_text().strip() == entry["sha256"], f"Invalid model marker: {marker}")
        target = payload / entry["path"]
        target.parent.mkdir(exist_ok=True)
        # APFS clones preserve the installed source and avoid extra staging storage.
        run("/bin/cp", "-c", source, target)
        run("/usr/bin/xattr", "-c", target)
        target.chmod(0o644)
        Path(str(target) + ".sha256").write_text(entry["sha256"])
    manifest = {"schemaVersion": 1, "files": files}
    (support / "ModelManifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    shutil.copytree(HERE / "model-licenses", support / "ModelLicenses")
    shutil.copyfile(HERE / "安装指南.txt", support / "安装指南.txt")
    run("/usr/bin/codesign", "--force", "--sign", identity,
        "--preserve-metadata=identifier,requirements,entitlements,flags,runtime", bundled)
    require(signing_certificate(app, stage.parent / "original-cert-") ==
            signing_certificate(bundled, stage.parent / "bundled-cert-"),
            "The app with models must use the same signing certificate as the original")
    entitlements = ["/usr/bin/codesign", "-d", "--entitlements", "-"]
    require(subprocess.check_output([*entitlements, app], stderr=subprocess.DEVNULL) ==
            subprocess.check_output([*entitlements, bundled], stderr=subprocess.DEVNULL),
            "The signed app with models must preserve entitlements")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", bundled)
    (stage / DESTINATION).symlink_to("/Applications", target_is_directory=True)


def verify_image(disk_image, mount, files):
    run("/usr/bin/hdiutil", "verify", disk_image)
    run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, disk_image)
    try:
        check_layout(mount)
        app = mount / APP
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        helpers = app / "Contents/Helpers"
        for helper in helpers.rglob("*"):
            if helper.is_file() and os.access(helper, os.X_OK):
                run("/usr/bin/codesign", "--verify", "--strict", helper)
        support = app / "Contents/SharedSupport"
        require(json.loads((support / "ModelManifest.json").read_bytes())
                == {"schemaVersion": 1, "files": files}, "Mounted manifest differs from release catalog")
        require((support / "ModelLicenses/模型来源.txt").is_file(), "Missing model licenses")
        seal = plistlib.loads((app / "Contents/_CodeSignature/CodeResources").read_bytes())["files2"]
        for entry in files:
            relative = "SharedSupport/Models/" + entry["path"]
            require(relative in seal and relative + ".sha256" in seal,
                    f"Model and marker must both be covered by the application signature: {relative}")
            model = support / "Models" / entry["path"]
            verify_file(model, entry)
            require(Path(str(model) + ".sha256").read_text() == entry["sha256"],
                    f"Invalid bundled model marker: {model}")
    finally:
        run("/usr/bin/hdiutil", "detach", mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--models", type=Path, help="Local installed models with checksum markers")
    sources.add_argument("--models-volume", type=Path, help="Read-only mounted SimuSub distribution")
    parser.add_argument("--source-image", type=Path, help="Backing DMG if renamed after mount")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--identity", required=True, help="Signing identity for the app and DMG")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    app = args.app.resolve(strict=True)
    require(not args.source_image or args.models_volume, "--source-image requires --models-volume")
    require(output.suffix.lower() == ".dmg" and not os.path.lexists(output),
            f"Expected a new .dmg output path: {output}")
    require(args.identity.strip() not in ("", "-"), "Use a stable signing identity")
    run("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    volume = "SimuSub " + info["CFBundleShortVersionString"] + " 安装盘"
    files = release_files(app)
    if args.models_volume:
        models = models_from_volume(args.models_volume.resolve(strict=True), args.source_image, files)
    else:
        models = args.models.expanduser().resolve(strict=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".simusub-dmg-", dir=output.parent) as temp:
        root = Path(temp)
        stage = root / "stage"
        stage.mkdir()
        make_stage(stage, app, models, args.identity, files, require_markers=args.models is not None)
        writable = root / "layout.dmg"
        run("/usr/bin/hdiutil", "create", "-srcfolder", stage, "-volname", volume, "-fs", "HFS+",
            "-format", "UDRW", writable)
        mount = root / "mount"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-readwrite", "-nobrowse", "-noautoopen",
            "-mountpoint", mount, writable)
        try:
            set_layout(mount, root, volume)
        finally:
            run("/usr/bin/hdiutil", "detach", mount)
        image = root / "installer.dmg"
        run("/usr/bin/hdiutil", "convert", writable, "-format", "ULFO", "-o", image)
        run("/usr/bin/codesign", "--sign", args.identity, image)
        run("/usr/bin/codesign", "--verify", "--strict", image)
        mount.mkdir(exist_ok=True)
        verify_image(image, mount, files)
        os.link(image, output)  # Publish only the verified image; never replace an existing delivery.
    print(f"Verified {len(files)} files ({sum(f['byteCount'] for f in files):,} bytes). {output}")


if __name__ == "__main__":
    main()
