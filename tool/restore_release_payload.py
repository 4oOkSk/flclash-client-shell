#!/usr/bin/env python3
"""Restore a bounded release payload from repository secrets."""

from __future__ import annotations

import base64
from io import BytesIO
import os
from pathlib import Path
import stat
import sys
import tarfile


EXPECTED = {
    "manifest.json": 64 * 1024,
    "icon-master.png": 2 * 1024 * 1024,
}


def fail(message: str) -> None:
    raise SystemExit(f"release payload: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("one output directory is required")
    output = Path(sys.argv[1])
    if output.exists() or output.is_symlink():
        fail("output path already exists")

    try:
        part_count = int(os.environ["RELEASE_PAYLOAD_PARTS"])
    except (KeyError, ValueError) as exc:
        raise SystemExit("release payload: invalid part count") from exc
    if not 1 <= part_count <= 32:
        fail("part count is outside the allowed range")

    chunks: list[str] = []
    for index in range(1, part_count + 1):
        name = f"RELEASE_PAYLOAD_{index:02d}"
        value = os.environ.get(name, "")
        if not value or any(character.isspace() for character in value):
            fail("a payload part is missing or malformed")
        chunks.append(value)
    for index in range(part_count + 1, 33):
        if os.environ.get(f"RELEASE_PAYLOAD_{index:02d}", ""):
            fail("an undeclared payload part is present")

    try:
        archive_bytes = base64.b64decode("".join(chunks), validate=True)
    except ValueError as exc:
        raise SystemExit("release payload: base64 decoding failed") from exc
    if not archive_bytes or len(archive_bytes) > 3 * 1024 * 1024:
        fail("archive size is invalid")

    with tarfile.open(fileobj=BytesIO(archive_bytes), mode="r:gz") as archive:
        members = archive.getmembers()
        if {member.name for member in members} != set(EXPECTED):
            fail("archive member set is invalid")
        for member in members:
            if not member.isfile() or member.issym() or member.islnk():
                fail("archive contains a non-regular member")
            if member.size <= 0 or member.size > EXPECTED[member.name]:
                fail("archive member size is invalid")

        output.mkdir(mode=0o700)
        for member in members:
            source = archive.extractfile(member)
            if source is None:
                fail("archive member cannot be read")
            destination = output / member.name
            descriptor = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as target:
                target.write(source.read())
                target.flush()
                os.fsync(target.fileno())
            if stat.S_IMODE(destination.stat().st_mode) != 0o600:
                fail("restored file permissions are invalid")

    print("release_payload=restored files=2")


if __name__ == "__main__":
    main()
