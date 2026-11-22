#!/usr/bin/env python3
"""Stage the pinned production DevTools resources and replace one theme file."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent
FRONTEND = Path("devtools-frontend/gen/third_party/devtools-frontend/src/front_end")


def resource_paths(manifest):
    paths = []
    for include in ET.fromstring(manifest).iter("include"):
        name = include.get("resource_path")
        if not name:
            continue  # The browser-only compressed CDP protocol is not a UI asset.
        path = PurePosixPath(name)
        if path.is_absolute() or any(part in ("", ".", "..") for part in name.split("/")) or "\\" in name:
            raise ValueError(f"Invalid resource path: {name}")
        paths.append(name)
    if not paths or len(paths) != len(set(paths)):
        raise ValueError("Empty or duplicate DevTools resource manifest")
    return sorted(paths)


def fingerprint(paths, read):
    digest = hashlib.sha256()
    for name in paths:
        digest.update(name.encode() + b"\0" + hashlib.sha256(read(name)).digest())
    return digest.hexdigest()


def build(destination, source=None):
    lock = json.loads((ROOT / "DevTools.lock").read_text())
    helium = json.loads((ROOT.parent / "macos/Sources/macos/Resources/sources.json").read_text())["helium"]
    if helium["chromiumVersion"].split(".")[0] != str(lock["chromiumMajor"]):
        raise ValueError("Update devtools/DevTools.lock alongside Helium's Chromium major version")
    archive = None
    if source and not Path(source).is_dir():
        raise ValueError(f"DEVTOOLS_SOURCE_DIR is not a front_end directory: {source}")
    source = Path(source) if source else ROOT / FRONTEND
    if source.is_dir():
        read = lambda name: (source / name).read_bytes()
    else:
        archive_path = ROOT / "devtools-frontend.zip"
        if not archive_path.is_file():
            archive_path = ROOT / ".cache" / f"{lock['snapshot']}.zip"
        if not archive_path.is_file():
            archive_path.parent.mkdir(parents=True, exist_ok=True)
            download = archive_path.with_suffix(".download")
            print(f"Downloading DevTools frontend only: {lock['url']}", flush=True)
            try:
                with urllib.request.urlopen(lock["url"], timeout=60) as response, download.open("wb") as output:
                    shutil.copyfileobj(response, output)
                download.replace(archive_path)
            finally:
                download.unlink(missing_ok=True)
        archive = zipfile.ZipFile(archive_path)
        read = lambda name: archive.read(f"{FRONTEND.as_posix()}/{name}")
    try:
        paths = resource_paths(read("devtools_resources.grd"))
        actual = fingerprint(paths, read)
        if actual != lock["resourcesSha256"]:
            raise ValueError(f"DevTools resource checksum mismatch: expected {lock['resourcesSha256']}, got {actual}")
        destination = Path(destination).resolve()
        if destination == source.resolve() or destination == ROOT:
            raise ValueError("The destination must be separate from the upstream assets and theme source")
        destination.mkdir(parents=True, exist_ok=True)
        expected = set(paths) | {"LICENSE", "GitHub-Theme-LICENSE.txt", "DevTools.lock"}
        for old in destination.rglob("*"):
            if old.is_file() and old.relative_to(destination).as_posix() not in expected:
                old.unlink()
        for name in paths:
            output = destination / name
            output.parent.mkdir(parents=True, exist_ok=True)
            contents = read(name)
            if name == "design_system_tokens.css":
                contents += b"\n" + (ROOT / "theme.css").read_bytes()
            output.write_bytes(contents)
        shutil.copyfile(ROOT / "LICENSE", destination / "LICENSE")
        shutil.copyfile(ROOT / "theme-source/LICENSE.txt", destination / "GitHub-Theme-LICENSE.txt")
        shutil.copyfile(ROOT / "DevTools.lock", destination / "DevTools.lock")
        size = sum((destination / name).stat().st_size for name in paths)
        print(f"Staged Chromium {lock['chromiumMajor']} DevTools: {len(paths)} assets, {size / 1_000_000:.1f} MB, GitHub Dark Default")
    finally:
        if archive:
            archive.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", default=str(ROOT / "assets"))
    parser.add_argument("--source", default=os.environ.get("DEVTOOLS_SOURCE_DIR"), help="Extracted front_end directory")
    args = parser.parse_args()
    try:
        build(args.destination, args.source)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"DevTools build failed: {error}\n")
