"""Lay out the mounted HFS+ volume, keeping the background alias on this volume."""

from pathlib import Path
import os
import subprocess

from ds_store import DSStore
from mac_alias import Alias

HERE = Path(__file__).resolve().parent
APP = "SimuSub.app"
DESTINATION = "应用程序"
POSITIONS = {APP: (159, 202), DESTINATION: (461, 202)}
ART = ".background.tiff"


def set_layout(mount, temp, volume):
    single, retina = temp / "background.png", temp / "background@2x.png"
    subprocess.run(["/usr/bin/xcrun", "swift", HERE / "DrawDiskBackdrop.swift", single, retina], check=True)
    subprocess.run(["/usr/bin/tiffutil", "-cathidpicheck", single, retina, "-out", mount / ART], check=True)
    alias = Alias.for_file(str(mount / ART))
    alias.volume.posix_path = ("/Volumes/" + volume).encode()
    alias.target.folder_name = volume.encode()
    with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
        root = store["."]
        root["vSrn"] = ("long", 1)
        root["icvl"] = ("type", b"icnv")
        root["bwsp"] = dict(WindowBounds="{{165, 120}, {620, 334}}",
                            ShowStatusBar=False, ContainerShowSidebar=False, PreviewPaneVisibility=False,
                            ShowTabView=False, ShowToolbar=False, ShowPathbar=False, ShowSidebar=False,
                            SidebarWidth=0)
        root["icvp"] = dict(viewOptionsVersion=1, backgroundType=2, backgroundImageAlias=alias.to_bytes(),
                            backgroundColorRed=0.93, backgroundColorGreen=0.91, backgroundColorBlue=0.96,
                            gridOffsetX=0.0, gridOffsetY=0.0, gridSpacing=100.0, arrangeBy="none",
                            showIconPreview=False, showItemInfo=False, labelOnBottom=True,
                            textSize=13.0, iconSize=96.0, scrollPositionX=0.0, scrollPositionY=0.0)
        for name, position in POSITIONS.items():
            store[name]["Iloc"] = position


def check_layout(mount):
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        options = store["."]["icvp"]
        if options["backgroundType"] != 2 or options["iconSize"] != 96:
            raise ValueError("Unexpected Finder icon view settings")
        alias = Alias.from_bytes(options["backgroundImageAlias"])
        if alias.target.cnid != (mount / ART).stat().st_ino:
            raise ValueError("Finder background alias no longer references the artwork")
        for name, expected in POSITIONS.items():
            if store[name]["Iloc"] != expected:
                raise ValueError(f"Unexpected Finder position for {name}")
    visible = {item.name for item in mount.iterdir() if not item.name.startswith(".")}
    if visible != set(POSITIONS):
        raise ValueError(f"Unexpected visible items in the installation image: {visible}")
    destination = mount / DESTINATION
    if not destination.is_symlink() or os.readlink(destination) != "/Applications":
        raise ValueError("Finder destination must link to the system Applications folder")
    if not (mount / APP).is_dir() or (mount / APP).is_symlink():
        raise ValueError("Finder source must be an actual application bundle")
