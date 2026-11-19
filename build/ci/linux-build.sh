#!/bin/bash
# CI helper used by .github/workflows/linux.yml.
#
# It prepares the Mozilla/comm sources, applies the Betterbird patch series,
# builds and packages Betterbird on a GitHub-hosted Linux runner.
#
# The build is run in the phases of build.sh (sources, patches, bootstrap,
# build, package) instead of a single "build.sh" call, so that an interrupted
# compile can be resumed. GitHub-hosted Linux runners occasionally send
# SIGTERM to the build process (observed as "Process completed with exit code
# 143" in the middle of a compile, without OOM or disk errors). Because the
# object directory of a Linux build cannot be persisted between runs (it is far
# too large for actions/cache), the resume happens inside the same job:
# "mach build" is started again on the existing object directory.
#
# Environment:
#   VERSION         ESR version to build. It may be a version number ("140") or
#                   a tag name ("140.0-automation"); only the first three
#                   characters are used.
#   MODE            "build" (default) or "prepare" (stop after cloning the
#                   sources and applying the patch series, smoke test).
#   BUDGET_MINUTES  Wall-clock minutes "mach build" may use, including all
#                   resumes (default 300).

set -euo pipefail

VERSION="${VERSION:?VERSION is not set}"
VER="${VERSION:0:3}"
MODE="${MODE:-build}"
BUDGET_MINUTES="${BUDGET_MINUTES:-300}"
BUDGET_SECONDS=$(( BUDGET_MINUTES * 60 ))

# Directory of this script is <repo>/build/ci, so the repository is two levels up.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(dirname "$REPO_DIR")"
cd "$BUILD_DIR"

echo "======================================================="
echo "Building Betterbird $VER ($MODE) on Linux"
echo "  repository: $REPO_DIR"
echo "  build dir:  $BUILD_DIR"
echo "  budget:     $BUDGET_MINUTES minutes for mach build (resumable)"
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

# Adjust the working copy of the mozconfig for a GitHub-hosted runner.
MOZCONFIG="$REPO_DIR/$VER/mozconfig-Linux"
# Normalise the line endings first, so the patterns below always match.
sed -i -e 's/\r$//' -e 's/^ac_add_options --enable-tests$/ac_add_options --disable-tests/' "$MOZCONFIG"
grep -q '^ac_add_options --disable-tests' "$MOZCONFIG" || echo 'ac_add_options --disable-tests' >> "$MOZCONFIG"
# The test-only targets are not part of the release archive, they only cost
# build time and memory. --enable-tests is the default for non-release builds,
# so the option has to be replaced by --disable-tests, not just dropped.
# "--disable-elf-hack" keeps the link step a bit lighter and the runner has no
# persistent compiler cache, so we build without ccache.
# "-k 0" lets make continue past unrelated failures, which matters when the
# build is resumed after an interrupt.
{
  echo 'ac_add_options --disable-elf-hack'
  echo 'mk_add_options MOZ_MAKE_FLAGS="-k 0"'
} >> "$MOZCONFIG"

if [ "$MODE" = "prepare" ]; then
  printf 'Y\n' | ./build.sh "$VER" apply
  echo "======================================================="
  echo "Sources prepared and patch series applied, not building in 'prepare' mode."
  exit 0
fi

# Sources and patches. With the sources already present this is a no-op pull.
printf 'Y\n' | ./build.sh "$VER" apply

# shellcheck disable=SC1090 # the name of the sourced file depends on the version
. "$REPO_DIR/$VER/$VER.sh"
MOZILLA_DIR="$(basename "$MOZILLA_REPO")"
cd "$MOZILLA_DIR"

# Toolchains (rust, clang, node) come from mach bootstrap, which build.sh would
# only run once per machine, controlled by a marker file.
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

cp "$REPO_DIR/$VER/mozconfig-Linux" mozconfig

echo "======================================================="
echo "Starting mach build, up to $BUDGET_MINUTES minutes across all attempts"
# GitHub-hosted runners occasionally send SIGTERM to the running step, which is
# what killed the earlier runs ("Process completed with exit code 143" in the
# middle of a compile, with no OOM and no disk error). Trap the signal here so
# that this script survives it: without the trap the shell dies and the job
# fails right away. The compile itself is not protected - it dies from the
# signal, which is why it is restarted on the object directory built so far.
term_signals=0
trap 'term_signals=$(( term_signals + 1 ))' TERM

# Runs "mach build" in the background for at most $1 seconds and returns its
# exit code. Running in the background is required for the TERM trap to fire;
# the wait is repeated whenever a trapped signal interrupted it.
run_mach_build() {
  timeout --signal=INT --kill-after=120 "$1" ./mach build &
  local pid=$! rc
  while :; do
    if wait "$pid"; then rc=0; else rc=$?; fi
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    break
  done
  return "$rc"
}

start_epoch=$(date +%s)
attempt=0
rc=1
while :; do
  elapsed=$(( $(date +%s) - start_epoch ))
  remaining=$(( BUDGET_SECONDS - elapsed ))
  if [ "$remaining" -le 300 ]; then
    echo "======================================================="
    echo "### The budget of $BUDGET_MINUTES minutes is used up after $(( elapsed / 60 )) minutes."
    echo "### Start the workflow again; a Linux build cannot be continued in a new run."
    exit 1
  fi
  attempt=$(( attempt + 1 ))
  echo "======================================================="
  echo "### mach build, attempt $attempt, $(( remaining / 60 )) minutes of budget left"
  set +e
  run_mach_build "$remaining"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    break
  fi
  case "$rc" in
    124 | 130 | 137 | 143)
      echo "======================================================="
      echo "### mach build was interrupted (exit code $rc, $term_signals SIGTERM(s) received)"
      echo "### after $(( ( $(date +%s) - start_epoch ) / 60 )) minutes of $BUDGET_MINUTES."
      echo "### Resuming the build in the existing object directory."
      sleep 15
      ;;
    *)
      echo "mach build failed with exit code $rc" >&2
      exit "$rc"
      ;;
  esac
done

echo "======================================================="
echo "Build finished, packaging"
./mach package

echo "======================================================="
shopt -s nullglob
archives=("$BUILD_DIR/$MOZILLA_DIR"/obj-*/dist/betterbird-*.tar.*)
if [ "${#archives[@]}" -eq 0 ]; then
  echo "No Betterbird archive was produced." >&2
  ls -l "$BUILD_DIR/$MOZILLA_DIR"/obj-*/dist/ >&2 || true
  exit 1
fi
printf 'Produced:\n'
printf '  %s\n' "${archives[@]}"
