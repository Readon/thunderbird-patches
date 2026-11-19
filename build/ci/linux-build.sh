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

# The test-only targets must not be built: they are not needed for the
# installer, they cost build time and memory, and on ESR 153 the gtest helper
# content_analysis_sdk_agent.exe does not link on Windows
# ("No rule to make target ...abseil-cpp...Unified_cpp_randen_hwaes_impl_gn0.obj").
# Note that --enable-tests is the default for non-release builds, so the option
# has to be replaced by --disable-tests, not just dropped.
sed -i -e 's/\r$//' -e 's/^ac_add_options --enable-tests$/ac_add_options --disable-tests/' "$REPO_DIR/$VER/mozconfig-Linux"
grep -q '^ac_add_options --disable-tests' "$REPO_DIR/$VER/mozconfig-Linux" || echo 'ac_add_options --disable-tests' >> "$REPO_DIR/$VER/mozconfig-Linux"

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
