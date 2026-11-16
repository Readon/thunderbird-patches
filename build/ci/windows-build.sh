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

# Safety net: a Windows checkout with core.autocrlf=true turns the patch files
# into CRLF files, which "hg qpush" cannot apply to the LF working copy.
if grep -qs $'\r' "$REPO_DIR/$VER/series-moz"; then
  echo "ERROR: the patch files were checked out with CRLF line endings." >&2
  echo "Check .gitattributes and core.autocrlf, see .github/workflows/windows.yml." >&2
  exit 1
fi
# must be enabled. build.sh does that itself on Linux/macOS by writing .hg/hgrc
# files, but on Windows it only appends to a mercurial.ini that is expected to
# exist on the developer's machine. Clone the repositories here and enable mq in
# the per-repository configuration, which Mercurial always reads.
# shellcheck disable=SC1090 # the name of the sourced file depends on the version
. "$REPO_DIR/$VER/$VER.sh"
MOZILLA_DIR="$(basename "$MOZILLA_REPO")"
if ! [ -d "$MOZILLA_DIR" ]; then
  echo "======================================================="
  echo "Cloning $MOZILLA_REPO"
  hg clone "$MOZILLA_REPO"
  echo "======================================================="
  echo "Cloning $COMM_REPO"
  ( cd "$MOZILLA_DIR" && hg clone "$COMM_REPO" comm )
fi
for repo in "$MOZILLA_DIR" "$MOZILLA_DIR/comm"; do
  if ! grep -qs '^mq[[:space:]]*=' "$repo/.hg/hgrc"; then
    printf '[extensions]\nmq =\n' >> "$repo/.hg/hgrc"
  fi
done

# build.sh only touches the mercurial.ini in the build directory if it exists.
if ! [ -f mercurial.ini ]; then
  printf '[ui]\n' > mercurial.ini
fi

# A few adjustments for a GitHub-hosted runner. They only touch the working copy
# of the mozconfig, the checked-in file stays untouched.
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
