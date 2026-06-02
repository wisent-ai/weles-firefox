#!/usr/bin/env bash
# Runs after `mach build` completes. Verifies the binary, tarballs a new
# release with the next WELES_FIREFOX_REV, updates the GitHub Release,
# and installs locally so weles trajectories pick up the juggler-enabled
# patched Firefox.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=mozilla-central/obj-weles/dist/Nightly.app/Contents/MacOS/firefox
if [[ ! -x "$BIN" ]]; then echo "FAIL: $BIN not present"; exit 1; fi
echo "=== 1. verify binary honors weles patches ==="
node scripts/verify.mjs || { echo "FAIL: verify.mjs did not pass"; exit 1; }

echo "=== 2. tarball new release (weles.2, juggler included) ==="
WELES_FIREFOX_REV=2 bash scripts/release.sh

TAG=$(grep "^to GitHub Release:" /dev/stdin 2>/dev/null | awk '{print $4}') || true
# Release tag is always firefox-<version>-weles.<rev>
VERSION=$(cat mozilla-central/browser/config/version.txt | tr -d '[:space:]')
TAG="firefox-${VERSION}-weles.2"
ASSET="artifacts/weles-firefox-${VERSION}-weles.2-macos-arm64.tar.gz"
mv weles-firefox-*-weles.2-macos-arm64.tar.gz "$ASSET" 2>/dev/null || true
[[ -f "$ASSET" ]] || ASSET=$(ls weles-firefox-${VERSION}-weles.2-macos-arm64.tar.gz 2>/dev/null)

echo "=== 3. attach asset to GitHub Release $TAG ==="
gh release create "$TAG" "$ASSET" --repo wisent-ai/weles-firefox --title "$TAG" \
  --notes "juggler-enabled build — weles patches + Playwright juggler. Applies bootstrap.diff fuzz=5 (58/69 clean, 11 rejected hunks skipped)." \
  || gh release upload "$TAG" "$ASSET" --repo wisent-ai/weles-firefox --clobber

echo "=== 4. install locally via download.sh ==="
rm -rf ~/.local/share/weles-firefox/${VERSION}-weles.2
WELES_FIREFOX_RELEASE="$TAG" bash ../weles/scripts/firefox/download.sh

echo "=== 5. integration test against weles WSession firefox path ==="
( cd ../weles && node scripts/firefox/integration_test.mjs )

echo "=== all post-build steps OK ==="
