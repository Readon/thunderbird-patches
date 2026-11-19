#!/bin/bash
# CI helper used by .github/workflows/windows.yml for "mode=build".
#
# "mach build" runs with a time budget. The workflow persists the sccache
# directory, so a run that stops because the budget is exhausted can be
# continued simply by starting the workflow again: the next run restores the
# cache and only compiles what is still missing.
#
# Environment:
#   VERSION         ESR version to build ("140" or "140.0-automation")
#   BUDGET_MINUTES  Minutes to spend on "mach build" (default 240)

set -euo pipefail

VERSION="${VERSION:?VERSION is not set}"
VER="${VERSION:0:3}"
BUDGET_MINUTES="${BUDGET_MINUTES:-240}"
BUDGET_SECONDS=$(( BUDGET_MINUTES * 60 ))

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(dirname "$REPO_DIR")"
cd "$BUILD_DIR"

echo "======================================================="
echo "Building Betterbird $VER on Windows (full build)"
echo "  repository: $REPO_DIR"
echo "  build dir:  $BUILD_DIR"
echo "  budget:     $BUDGET_MINUTES minutes for mach build"
echo "  sccache:    ${SCCACHE_DIR:-<default>} (size ${SCCACHE_CACHE_SIZE:-<default>})"
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

# build.sh applies the patch series with "hg qpush", so Mercurial's mq extension
# must be enabled before it runs. On Windows build.sh expects a mercurial.ini,
# but only the per-repository configuration is guaranteed to be read.
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
if ! [ -f mercurial.ini ]; then
  printf '[ui]\n' > mercurial.ini
fi

# Adjust the working copy of the mozconfig for a GitHub-hosted runner: drop the
# WIN32_REDIST_DIR of the release machine, use the compiler cache that the
# workflow persists, and stay within the memory and core count of the runner.
MOZCONFIG="$REPO_DIR/$VER/mozconfig"
if [ -f "$MOZCONFIG" ]; then
  # Normalise the line endings first, otherwise the patterns below do not match
  # on a checkout that used core.autocrlf.
  sed -i 's/\r$//' "$MOZCONFIG"
  sed -i '/^export WIN32_REDIST_DIR/d' "$MOZCONFIG"
  # The test-only targets must not be built: they are not needed for the
  # installer, they cost build time, and the gtest helper
  # content_analysis_sdk_agent.exe does not link on Windows in ESR 153
  # ("No rule to make target ...abseil-cpp...Unified_cpp_randen_hwaes_impl_gn0.obj").
  # --enable-tests is the default for non-release builds, so the option has to
  # be replaced by --disable-tests, not just dropped.
  sed -i 's/^ac_add_options --enable-tests$/ac_add_options --disable-tests/' "$MOZCONFIG"
  grep -q '^ac_add_options --disable-tests' "$MOZCONFIG" || echo 'ac_add_options --disable-tests' >> "$MOZCONFIG"
  {
    echo 'mk_add_options MOZ_MAKE_FLAGS="-j4"'
    echo 'ac_add_options --disable-lto'
    echo 'ac_add_options --with-ccache=sccache'
  } >> "$MOZCONFIG"
fi

# Sources and patches. With the sources already present this is a no-op pull.
printf 'Y\n' | ./build.sh "$VER" apply

cd "$MOZILLA_DIR"

# Toolchains (clang, rust, sccache, ...) come from mach bootstrap.
if [ -f "$HOME/.mozbuild/ci-bootstrap-done-$VER" ]; then
  echo "Bootstrap was already run in this job."
else
  echo "======================================================="
  echo "Running mach bootstrap"
  ./mach --no-interactive bootstrap --application-choice "Firefox for Desktop"
  mkdir -p "$HOME/.mozbuild"
  touch "$HOME/.mozbuild/ci-bootstrap-done-$VER"
fi
if [ -x "$HOME/.cargo/bin/rustup" ]; then
  "$HOME/.cargo/bin/rustup" override set "$RUST_VER"
fi

cp "$REPO_DIR/$VER/mozconfig" mozconfig

echo "======================================================="
echo "Starting mach build, stopping after $BUDGET_MINUTES minutes at the latest"
set +e
timeout --signal=INT --kill-after=120 "$BUDGET_SECONDS" ./mach build
rc=$?
set -e

if [ "$rc" -eq 124 ] || [ "$rc" -eq 130 ] || [ "$rc" -eq 137 ]; then
  echo "======================================================="
  echo "### Budget of $BUDGET_MINUTES minutes exhausted."
  echo "### The compiler cache has been filled with everything built so far."
  echo "### Start the workflow again to continue where this run stopped."
  touch "$BUILD_DIR/ci-build-budget"
  exit 0
fi

if [ "$rc" -ne 0 ]; then
  echo "mach build failed with exit code $rc" >&2
  exit "$rc"
fi

echo "======================================================="
echo "Build finished within the budget, packaging"
./mach package

echo "======================================================="
shopt -s nullglob
installers=(obj-*/dist/install/sea/*.installer.exe)
if [ "${#installers[@]}" -eq 0 ]; then
  echo "No Betterbird installer was produced." >&2
  ls -l obj-*/dist/install/sea/ >&2 || true
  exit 1
fi
printf 'Produced:\n'
printf '  %s\n' "${installers[@]}"
touch "$BUILD_DIR/ci-build-complete"
