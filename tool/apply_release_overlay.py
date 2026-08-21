#!/usr/bin/env python3
"""Apply data-only release branding without storing it in the public tree."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SKIP_PARTS = {".git", ".dart_tool", "build", "dist"}


def fail(message: str) -> None:
    raise SystemExit(f"release overlay: {message}")


def load_manifest(path: Path) -> dict[str, object]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit("release overlay: manifest is unreadable") from exc
    expected = {
        "schema",
        "replacements",
        "website_url",
        "android_certificate_sha256",
        "icon_source_path",
        "icon_target_path",
    }
    if not isinstance(manifest, dict) or set(manifest) != expected:
        fail("manifest schema is invalid")
    if manifest["schema"] != 1:
        fail("manifest version is unsupported")
    replacements = manifest["replacements"]
    if not isinstance(replacements, list) or not 1 <= len(replacements) <= 32:
        fail("replacement list is invalid")
    seen: set[str] = set()
    for replacement in replacements:
        if not isinstance(replacement, dict) or set(replacement) != {"from", "to"}:
            fail("replacement entry is invalid")
        source = replacement["from"]
        target = replacement["to"]
        if (
            not isinstance(source, str)
            or not isinstance(target, str)
            or not source
            or not target
            or source == target
            or source in seen
            or "\x00" in source + target
        ):
            fail("replacement values are invalid")
        seen.add(source)
    website = manifest["website_url"]
    if (
        not isinstance(website, str)
        or not website.startswith("https://")
        or any(character.isspace() for character in website)
    ):
        fail("website URL is invalid")
    digest = manifest["android_certificate_sha256"]
    if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
        fail("Android certificate digest is invalid")
    for key in ("icon_source_path", "icon_target_path"):
        value = manifest[key]
        if (
            not isinstance(value, str)
            or not value
            or Path(value).is_absolute()
            or ".." in Path(value).parts
        ):
            fail("icon path is invalid")
    return manifest


def iter_files(root: Path):
    for path in root.rglob("*"):
        if any(part in SKIP_PARTS for part in path.relative_to(root).parts):
            continue
        if path.is_symlink():
            fail("source tree contains a symlink")
        if path.is_file():
            yield path


def write_github_environment(path: Path, manifest: dict[str, object]) -> None:
    replacements = manifest["replacements"]
    assert isinstance(replacements, list)
    mask_values = [item["to"] for item in replacements]
    mask_values.append(manifest["website_url"])
    mask_values.append(manifest["android_certificate_sha256"])
    for value in mask_values:
        print(f"::add-mask::{value}")
    website = manifest["website_url"]
    assert isinstance(website, str)
    with path.open("a", encoding="utf-8", newline="\n") as output:
        output.write(f"PRIVATE_CLIENT_WEBSITE_URL={website}\n")
        output.write(
            "EXPECTED_ANDROID_CERT_SHA256="
            f"{manifest['android_certificate_sha256']}\n"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--icon", type=Path, required=True)
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()

    root = args.root.resolve(strict=True)
    manifest = load_manifest(args.manifest)
    if args.github_env is not None:
        write_github_environment(args.github_env, manifest)

    replacements = manifest["replacements"]
    assert isinstance(replacements, list)
    changed = 0
    for path in iter_files(root):
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        replaced = text
        for item in replacements:
            replaced = replaced.replace(item["from"], item["to"])
        if replaced != text:
            path.write_text(replaced, encoding="utf-8", newline="\n")
            changed += 1

    source_icon = root / manifest["icon_source_path"]
    target_icon = root / manifest["icon_target_path"]
    if not source_icon.is_file() or source_icon.is_symlink() or target_icon.exists():
        fail("icon source or target state is invalid")
    icon_bytes = args.icon.read_bytes()
    if not icon_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        fail("release icon is not a PNG")
    target_icon.parent.mkdir(parents=True, exist_ok=True)
    os.replace(source_icon, target_icon)
    target_icon.write_bytes(icon_bytes)

    generic_values = [item["from"] for item in replacements]
    for path in iter_files(root):
        relative = path.relative_to(root).as_posix()
        if any(value in relative for value in generic_values):
            fail("generic marker remains in a path")
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if any(value in text for value in generic_values):
            fail("generic marker remains in source")
    print(f"release_overlay=applied text_files={changed} icon=restored")


if __name__ == "__main__":
    main()
