#!/usr/bin/env bash
# Reproducible build of the weles-patched Firefox.
#
# Usage:
#   bash build.sh             # bootstrap (if needed) + apply patches + build
#   bash build.sh --no-build  # just bootstrap + apply patches (prep only)
#
# Output:
#   mozilla-central/obj-weles/dist/Nightly.app/Contents/MacOS/firefox  (macOS)
#   mozilla-central/obj-weles/dist/bin/firefox                         (Linux)
#
# Consumed by weles/src/session/find_browser.ts::findCustomBrowser('firefox')
# which scans the obj-weles/dist/ path.

set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -d mozilla-central ]]; then
  echo "ERROR: mozilla-central/ not present. Clone with:" >&2
  echo "  git clone --depth 1 --filter=blob:none https://github.com/mozilla/gecko-dev.git mozilla-central" >&2
  exit 1
fi

cd mozilla-central

# Idempotent patch apply. `git apply --check` exits non-zero if already applied
# or if hunks don't match; handle both.
for p in ../patches/*.patch; do
  name=$(basename "$p")
  if git apply --reverse --check "$p" 2>/dev/null; then
    echo "[build.sh] $name already applied — skipping"
  elif git apply --check "$p" 2>/dev/null; then
    echo "[build.sh] applying $name ..."
    git apply "$p"
  else
    echo "ERROR: $name does not apply cleanly to this tree. Rebase the patch." >&2
    exit 1
  fi
done

# Bootstrap toolchain if missing
if [[ ! -d "$HOME/.mozbuild/clang" ]]; then
  echo "[build.sh] running mach bootstrap ..."
  yes | ./mach bootstrap --application-choice=browser
else
  echo "[build.sh] toolchain already present in ~/.mozbuild/clang — skipping bootstrap"
fi

if [[ "${1:-}" == "--no-build" ]]; then
  echo "[build.sh] --no-build: stopping before mach build"
  exit 0
fi

echo "[build.sh] starting mach build (this takes 4-8 hours on first build) ..."
./mach build

echo "[build.sh] build complete."
echo "[build.sh] binary: $(pwd)/obj-weles/dist/Nightly.app/Contents/MacOS/firefox"
