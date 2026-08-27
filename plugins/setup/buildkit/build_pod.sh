#!/usr/bin/env bash
set -euo pipefail

# This script is invoked by the CocoaPods script build phase.
# It forwards Xcode build environment to the build_tool and runs it.

# Xcode strips PATH to a minimal set. Restore common tool locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/fvm/default/bin:${HOME}/.pub-cache/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${PODS_ROOT:-$PWD}/../.." && pwd)"

FLUTTER_EXPORT_BUILD_ENVIRONMENT="${PODS_ROOT}/../Flutter/ephemeral/flutter_export_environment.sh"
if [ -f "$FLUTTER_EXPORT_BUILD_ENVIRONMENT" ]; then
  # shellcheck disable=SC1090
  source "$FLUTTER_EXPORT_BUILD_ENVIRONMENT"
fi

# Forward CocoaPods/Xcode environment to variables the build_tool expects.
export BUILDKIT_CONFIGURATION="${CONFIGURATION:-Release}"
export PROJECT_DIR

if [ -z "${APP_ENV:-}" ]; then
  export APP_ENV="pre"
fi

build_args=(macos)
has_arm64=false
has_x86_64=false
case " ${ARCHS:-} " in *' arm64 '*) has_arm64=true ;; esac
case " ${ARCHS:-} " in *' x86_64 '*) has_x86_64=true ;; esac

if $has_arm64 && $has_x86_64; then
  build_args+=(--arch universal)
elif $has_arm64; then
  build_args+=(--arch arm64)
elif $has_x86_64; then
  build_args+=(--arch amd64)
else
  echo "Error: Unsupported or empty macOS ARCHS: ${ARCHS:-<empty>}" >&2
  exit 1
fi

"$SCRIPT_DIR/run_build_tool.sh" "${build_args[@]}"

# Match Cargokit's phony input strategy so CocoaPods invokes the build tool on
# every native build and lets setup's fingerprint cache decide what to compile.
ln -fs "$OBJROOT/XCBuildData/build.db" "${BUILT_PRODUCTS_DIR}/buildkit_phony"
ln -fs "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}" "${BUILT_PRODUCTS_DIR}/buildkit_phony_out"
