#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'sensitive gate: %s\n' "$1" >&2
  exit 1
}

print_paths() {
  local path
  for path in "$@"; do
    printf '  - %s\n' "$path" >&2
  done
}

scan_source() {
  local path pattern
  local -a forbidden_paths=()
  local -a matches=()
  local -a patterns=(
    '/(link|sub|subscribe)/[A-Za-z0-9._~-]{20,}'
    '(vless|vmess|trojan|ssr|hysteria2?|tuic)://[^[:space:]<>]{20,}'
    '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'PRIVATE_CLIENT_ENROLL_BLOB[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=_-]{24,}'
    'enroll(ClientBlobPriv|ClientBlobPub|PanelSigPub|CacheKey)=[A-Za-z0-9+/=_-]{16,}'
  )

  shopt -s nocasematch
  while IFS= read -r -d '' path; do
    case "$path" in
      .env|.env.*|*/.env|*/.env.*|env.json|*/env.json|local.properties|*/local.properties|\
      *.jks|*.keystore|*.p12|*.pfx|*.mobileprovision|*.provisionprofile)
        forbidden_paths+=("$path")
        ;;
    esac
  done < <(git ls-files -z)
  shopt -u nocasematch

  if ((${#forbidden_paths[@]})); then
    printf 'sensitive gate: forbidden tracked build inputs found:\n' >&2
    print_paths "${forbidden_paths[@]}"
    exit 1
  fi

  for pattern in "${patterns[@]}"; do
    matches=()
    while IFS= read -r path; do
      matches+=("$path")
    done < <(
      git grep -I -l -E -e "$pattern" -- . \
        ':(exclude).github/scripts/ci-sensitive-gate.sh' \
        ':(exclude)android/app/google-services.json' || true
    )
    if ((${#matches[@]})); then
      printf 'sensitive gate: high-risk literal found in tracked source:\n' >&2
      print_paths "${matches[@]}"
      exit 1
    fi
  done

  if git grep -I -q -E '\$\{\{[[:space:]]*secrets\.' -- \
    .github/workflows/private-client-test-build.yml; then
    fail 'test-build workflow must not consume repository or environment secrets'
  fi

  printf 'sensitive gate: tracked source passed\n'
}

validate_release_settings() {
  local value
  local api_base=${PRIVATE_CLIENT_API_BASE:-}
  [[ "$api_base" == https://* ]] || fail 'client API base must use HTTPS'
  [[ "$api_base" != https://example.invalid* ]] || fail 'release API base is a placeholder'
  [[ -n "${PRIVATE_CLIENT_API_USER_AGENT:-}" ]] || fail 'client API user agent is missing'
  for value in \
    "${PRIVATE_CLIENT_LOGIN_PATH:-}" \
    "${PRIVATE_CLIENT_CONFIG_PATH:-}" \
    "${PRIVATE_CLIENT_LOGOUT_PATH:-}"; do
    [[ "$value" == /* ]] || fail 'client API paths must be absolute paths'
    [[ "$value" != *[$'\r\n\t ']* ]] || fail 'client API paths must not contain whitespace'
  done
}

scan_artifacts() {
  local artifact_root=${2:-dist}
  local path pattern destination
  local -a forbidden_paths=()
  local -a raw_matches=()
  local expanded_root
  local -a patterns=(
    '/(link|sub|subscribe)/[A-Za-z0-9._~-]{20,}'
    '(vless|vmess|trojan|ssr|hysteria2?|tuic)://[^[:space:]<>]{20,}'
    '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'PRIVATE_CLIENT_ENROLL_BLOB[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=_-]{24,}'
  )

  [[ -d "$artifact_root" ]] || fail 'artifact directory is missing'
  expanded_root=$(mktemp -d)
  trap 'rm -rf -- "$expanded_root"' RETURN

  shopt -s nocasematch
  while IFS= read -r -d '' path; do
    case "$path" in
      */env.json|*/local.properties|*.jks|*.keystore|*.p12|*.pfx|\
      *.mobileprovision|*.provisionprofile)
        forbidden_paths+=("$path")
        ;;
    esac
  done < <(find "$artifact_root" -type f -print0)
  shopt -u nocasematch

  if ((${#forbidden_paths[@]})); then
    printf 'sensitive gate: forbidden standalone files found in artifact set:\n' >&2
    print_paths "${forbidden_paths[@]}"
    exit 1
  fi

  local index=0
  while IFS= read -r -d '' path; do
    index=$((index + 1))
    destination="$expanded_root/$index"
    mkdir -p "$destination"
    case "$path" in
      *.apk|*.APK|*.zip|*.ZIP)
        command -v unzip >/dev/null || fail 'unzip is required to inspect APK/ZIP artifacts'
        unzip -qq "$path" -d "$destination" || fail "cannot unpack $(basename "$path")"
        ;;
      *.deb|*.DEB)
        command -v dpkg-deb >/dev/null || fail 'dpkg-deb is required to inspect DEB artifacts'
        dpkg-deb -x "$path" "$destination" || fail "cannot unpack $(basename "$path")"
        ;;
      *.tar|*.TAR|*.tar.gz|*.TAR.GZ|*.tgz|*.TGZ|*.tar.xz|*.TAR.XZ)
        tar -xf "$path" -C "$destination" || fail "cannot unpack $(basename "$path")"
        ;;
      *.dmg|*.DMG)
        [[ "$(uname -s)" == Darwin ]] || fail 'DMG artifacts must be inspected on macOS'
        local mount_dir="$destination/mount"
        mkdir -p "$mount_dir" "$destination/content"
        hdiutil attach "$path" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null
        cp -a "$mount_dir/." "$destination/content/"
        hdiutil detach "$mount_dir" >/dev/null
        rmdir "$mount_dir"
        ;;
    esac
  done < <(find "$artifact_root" -type f -print0)

  for pattern in "${patterns[@]}"; do
    raw_matches=()
    while IFS= read -r path; do
      raw_matches+=("$path")
    done < <(
      grep -aIlrE -e "$pattern" "$artifact_root" "$expanded_root" 2>/dev/null || true
    )
    if ((${#raw_matches[@]})); then
      printf 'sensitive gate: high-risk literal found in artifact set:\n' >&2
      print_paths "${raw_matches[@]}"
      exit 1
    fi
  done

  printf 'sensitive gate: recursively inspected artifact set passed\n'
}

self_test() {
  local temp_root status python_cmd
  temp_root=$(mktemp -d)
  trap 'rm -rf -- "$temp_root"' RETURN
  mkdir -p "$temp_root/payload" "$temp_root/artifacts"
  printf '%s\n' '/link/0123456789abcdefghijklmnopqrstuvwxyz' \
    > "$temp_root/payload/should-fail.txt"
  python_cmd=$(command -v python3 || command -v python || true)
  [[ -n "$python_cmd" ]] || fail 'Python is required for the recursive archive self-test'
  "$python_cmd" - "$temp_root/payload/should-fail.txt" \
    "$temp_root/artifacts/sample.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.write(sys.argv[1], 'should-fail.txt')
PY
  set +e
  (scan_artifacts generated "$temp_root/artifacts") >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'recursive artifact gate did not reject the injected sample'
  printf 'sensitive gate: recursive archive self-test passed\n'
}

case "${1:-source}" in
  source)
    scan_source
    ;;
  release-settings)
    validate_release_settings
    ;;
  artifacts)
    scan_artifacts "$@"
    ;;
  self-test)
    self_test
    ;;
  *)
    fail 'usage: ci-sensitive-gate.sh source | release-settings | artifacts [dir] | self-test'
    ;;
esac
