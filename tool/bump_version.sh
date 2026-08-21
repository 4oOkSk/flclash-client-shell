#!/usr/bin/env bash
set -euo pipefail

build_number="${1:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pubspec_file="${PUBSPEC_FILE:-"$script_dir/../pubspec.yaml"}"

usage() {
  cat <<'EOF'
Usage: tool/bump_version.sh YYYYMMDDNN

The release authority allocates YYYYMMDDNN in Asia/Shanghai. This helper only
applies an already reserved build number; it never chooses or reuses one.
EOF
}

if [[ ! $build_number =~ ^[0-9]{10}$ ]]; then
  usage >&2
  exit 64
fi
date_part=${build_number:0:8}
ordinal=${build_number:8:2}
year=$((10#${date_part:0:4}))
month=$((10#${date_part:4:2}))
day=$((10#${date_part:6:2}))
if ((year < 2000 || month < 1 || month > 12)); then
  echo "Invalid calendar date in build number: $build_number" >&2
  exit 64
fi
max_day=31
case "$month" in
  4|6|9|11) max_day=30 ;;
  2)
    if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then
      max_day=29
    else
      max_day=28
    fi
    ;;
esac
if ((day < 1 || day > max_day)); then
  echo "Invalid calendar date in build number: $build_number" >&2
  exit 64
fi
if ((10#$ordinal < 1 || 10#$ordinal > 99)); then
  echo "Build ordinal must be between 01 and 99" >&2
  exit 64
fi

version_line="$(grep -E '^version: 0\.0\.1\+[0-9]{10}$' "$pubspec_file" || true)"
if [[ -z "$version_line" ]]; then
  echo "No fixed 0.0.1 version line found in $pubspec_file" >&2
  exit 1
fi

version="${version_line#version: }"
new_version="0.0.1+$build_number"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
sed "s/^version: .*/version: $new_version/" "$pubspec_file" >"$tmp_file"
chmod 0644 "$tmp_file"
mv "$tmp_file" "$pubspec_file"
trap - EXIT

echo "$version -> $new_version"
