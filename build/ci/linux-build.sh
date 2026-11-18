#!/bin/bash
# CI helper used by .github/workflows/linux.yml.
#
# It prepares the Mozilla/comm sources, applies the Betterbird patch series,
# builds and packages Betterbird on a GitHub-hosted Linux runner.
#
# Environment:
#   VERSION  ESR version to build. It may be a version number ("140") or a tag
#            name ("140.0-automation"); only the first three characters are used.
#   MODE     "build" (default) or "prepare" (stop after cloning the sources and
#            applying the patch series, useful as a quick smoke test).

set -euo pipefail

VERSION="${VERSION:?VERSION is not set}"
VER="${VERSION:0:3}"
MODE="${MODE:-build}"

# Directory of this script is <repo>/build/ci, so the repository is two levels up.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(dirname "$REPO_DIR")"
cd "$BUILD_DIR"

echo "======================================================="
echo "Building Betterbird $VER ($MODE)"
echo "  repository: $REPO_DIR"
echo "  build dir:  $BUILD_DIR"
echo "======================================================="
df -h . || true

if [ "$(basename "$REPO_DIR")" != "thunderbird-patches" ]; then
  echo "This repository must be checked out into a directory called" >&2
  echo "'thunderbird-patches', next to the build directory, because" >&2
  echo "build.sh expects that layout (in GitHub Actions: actions/checkout" >&2
  echo "with 'path: thunderbird-patches')." >&2
  exit 1
fi

if ! [ -d "$REPO_DIR/$VER" ]; then
  echo "Version $VER is not available in this repository." >&2
  exit 1
fi

cp "$REPO_DIR/build/build.sh" .

# CI does not need the test-only targets, and on ESR 153 they break the build
# ("No rule to make target ...abseil-cpp...Unified_cpp_randen_hwaes_impl_gn0.obj"
# while linking dist/bin/content_analysis_sdk_agent.exe).
sed -i '/^ac_add_options --enable-tests/d' "$REPO_DIR/$VER/mozconfig-Linux" 2>/dev/null || true

# The runner has 4 cores. Fewer parallel jobs keep the peak memory lower than
# the "-j8" of the checked-in mozconfig, which caused silent kills of the job.
{
  echo 'mk_add_options MOZ_MAKE_FLAGS="-j4"'
  echo 'ac_add_options --disable-elf-hack'
} >> "$REPO_DIR/$VER/mozconfig-Linux"

if [ "$MODE" = "prepare" ]; then
  printf 'Y\n' | ./build.sh "$VER" apply
else
  printf 'Y\n' | ./build.sh "$VER"
fi

if [ "$MODE" = "prepare" ]; then
  echo "======================================================="
  echo "Sources prepared and patch series applied, not building in 'prepare' mode."
  exit 0
fi

echo "======================================================="
shopt -s nullglob
archives=("$BUILD_DIR"/mozilla-esr"$VER"/obj-*/dist/betterbird-*.tar.*)
if [ "${#archives[@]}" -eq 0 ]; then
  echo "No Betterbird archive was produced." >&2
  ls -l "$BUILD_DIR"/mozilla-esr"$VER"/obj-*/dist/ >&2 || true
  exit 1
fi
printf 'Produced:\n'
printf '  %s\n' "${archives[@]}"
