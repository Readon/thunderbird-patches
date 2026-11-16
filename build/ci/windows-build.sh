#!/bin/bash
# CI helper used by .github/workflows/windows.yml.
#
# It runs *inside* the MozillaBuild (MSYS2) shell, prepares the Mozilla/comm
# sources, applies the Betterbird patch series, builds and packages Betterbird
# on a GitHub-hosted Windows runner.
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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(dirname "$REPO_DIR")"
cd "$BUILD_DIR"

echo "======================================================="
echo "Building Betterbird $VER ($MODE)"
echo "  repository: $REPO_DIR"
echo "  build dir:  $BUILD_DIR"
echo "  uname:      $(uname -a)"
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

# On Windows build.sh does not write .hg/hgrc files but expects a mercurial.ini
# in the build directory and adds the mq extension to it.
if ! [ -f mercurial.ini ]; then
  printf '[ui]\n' > mercurial.ini
fi

# A few adjustments for a GitHub-hosted runner. They only touch the working
# copy of the mozconfig, the checked-in file stays untouched.
MOZCONFIG="$REPO_DIR/$VER/mozconfig"
if [ -f "$MOZCONFIG" ]; then
  # The checked-in mozconfig points WIN32_REDIST_DIR at a directory of the
  # release build machine; let the build system autodetect the redistributable
  # of the Visual Studio installation present on the runner instead.
  sed -i '/^export WIN32_REDIST_DIR/d' "$MOZCONFIG"
  # The hosted runner has fewer cores and less RAM than the reference machine.
  {
    echo 'mk_add_options MOZ_MAKE_FLAGS="-j4"'
    echo 'ac_add_options --disable-lto'
  } >> "$MOZCONFIG"
fi

if [ "$MODE" = "prepare" ]; then
  printf 'Y\n' | ./build.sh "$VER" apply
else
  printf 'Y\n' | ./build.sh "$VER"
fi

if [ "$MODE" = "prepare" ]; then
  echo "======================================================="
  echo "Sources prepared and patch series applied, not building in 'prepare' mode."
  touch "$BUILD_DIR/ci-build-succeeded"
  exit 0
fi

echo "======================================================="
shopt -s nullglob
installers=("$BUILD_DIR"/mozilla-esr"$VER"/obj-*/dist/install/sea/*.installer.exe)
if [ "${#installers[@]}" -eq 0 ]; then
  echo "No Betterbird installer was produced." >&2
  ls -l "$BUILD_DIR"/mozilla-esr"$VER"/obj-*/dist/install/sea/ >&2 || true
  exit 1
fi
printf 'Produced:\n'
printf '  %s\n' "${installers[@]}"

# start-shell.bat does not reliably propagate the exit code, the workflow checks
# for this marker instead.
touch "$BUILD_DIR/ci-build-succeeded"
