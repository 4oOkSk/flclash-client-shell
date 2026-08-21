#!/usr/bin/env python3
"""Restore a bounded release payload from a decrypted archive."""

from __future__ import annotations

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
    if len(sys.argv) != 3:
        fail("an archive and one output directory are required")
    archive_path = Path(sys.argv[1])
    output = Path(sys.argv[2])
    if output.exists() or output.is_symlink():
        fail("output path already exists")
    if not archive_path.is_file() or archive_path.is_symlink():
        fail("archive path is invalid")
    archive_bytes = archive_path.read_bytes()
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
            if os.name != "nt" and stat.S_IMODE(destination.stat().st_mode) != 0o600:
                fail("restored file permissions are invalid")

    print("release_payload=restored files=2")


if __name__ == "__main__":
    main()
