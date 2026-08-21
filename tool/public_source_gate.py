#!/usr/bin/env python3
"""Fail closed if public source contains private branding or build inputs."""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys


FORBIDDEN_HEX = (
    "636f6e6e65636174",
    "6f6f69636174",
    "306f69636174",
    "76326d656f77",
    "6361746f6d6174696f6e",
)
FORBIDDEN_SUFFIXES = (
    ".jks",
    ".keystore",
    ".p12",
    ".pfx",
    ".mobileprovision",
    ".provisionprofile",
)
EXPECTED_GENERIC_ICON_SHA256 = (
    "b6045af66e2e765643a50ac4871d388a9004e90dea93046696ac742ff8bf2e23"
)
EXPECTED_GENERIC_BRANDING_SET_SHA256 = (
    "b3e890df2518386632f2eff6f3f697afa3132c3070e669fc68ed513cdf72a09f"
)
GENERIC_BRANDING_PATHS = (
    "assets/images/icon.png",
    "android/app/src/main/ic_launcher-playstore.png",
    "android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png",
    "android/service/src/main/res/drawable-nodpi/ic.png",
    "android/service/src/main/res/drawable-nodpi/ic_service.png",
    "android/app/src/main/res/mipmap-xhdpi/ic_banner.png",
    "windows/runner/resources/app_icon.ico",
    "assets/images/icon.ico",
    "assets/images/icon/status_template.png",
    *(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png"
      for size in (16, 32, 64, 128, 256, 512, 1024)),
    *(f"android/app/src/main/res/mipmap-{density}/ic_launcher{suffix}.png"
      for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
      for suffix in ("", "_round")),
    *(f"assets/images/icon/status_{state}.{extension}"
      for state in (1, 2, 3)
      for extension in ("png", "ico")),
)


def fail(message: str) -> None:
    raise SystemExit(f"public source gate: {message}")


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) == 2 else ".").resolve(strict=True)
    forbidden = tuple(bytes.fromhex(value) for value in FORBIDDEN_HEX)
    checked = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ".git" in relative.parts:
            continue
        if path.is_symlink():
            fail("symlink is not allowed")
        folded_path = relative.as_posix().encode("utf-8").lower()
        if any(marker in folded_path for marker in forbidden):
            fail("private marker appears in a path")
        if not path.is_file():
            continue
        checked += 1
        name = path.name.lower()
        if name == ".env" or name.startswith(".env.") or name.endswith(FORBIDDEN_SUFFIXES):
            fail("forbidden build input is tracked")
        data = path.read_bytes()
        folded = data.lower()
        if any(marker in folded for marker in forbidden):
            fail("private marker appears in file content")

    icon = root / "assets/branding/harborproxy-icon-master.png"
    if not icon.is_file():
        fail("generic icon master is missing")
    if hashlib.sha256(icon.read_bytes()).hexdigest() != EXPECTED_GENERIC_ICON_SHA256:
        fail("generic icon master identity changed")

    branding_digest = hashlib.sha256()
    for relative in sorted(GENERIC_BRANDING_PATHS):
        path = root / relative
        if not path.is_file():
            fail("generic branding asset is missing")
        branding_digest.update(relative.encode("utf-8"))
        branding_digest.update(b"\0")
        branding_digest.update(hashlib.sha256(path.read_bytes()).digest())
    if branding_digest.hexdigest() != EXPECTED_GENERIC_BRANDING_SET_SHA256:
        fail("generic branding assets changed")
    print(f"public_source_gate=ok files={checked} private_markers=0")


if __name__ == "__main__":
    main()
