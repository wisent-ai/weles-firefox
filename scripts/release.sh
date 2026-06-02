#!/usr/bin/env bash
# Tarball the built weles-firefox into the shape scripts/firefox/download.sh
# expects from a GitHub Release (weles-firefox-<version>-<platform>.tar.gz).
#
# Run after build.sh completes. Output: ./weles-firefox-<version>-<plat>.tar.gz
# and its sha256. Uploading to a GitHub Release is operator-side.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d mozilla-central/obj-weles/dist ]]; then
  echo "ERROR: mozilla-central/obj-weles/dist not found. Run build.sh first." >&2
  exit 1
fi

VERSION=$(cat mozilla-central/browser/config/version.txt | tr -d '[:space:]')
if [[ -z "$VERSION" ]]; then
  echo "ERROR: could not read version from browser/config/version.txt" >&2
  exit 1
fi
WELES_REV="${WELES_FIREFOX_REV:-1}"
TAG="${VERSION}-weles.${WELES_REV}"

uname_s=$(uname -s)
uname_m=$(uname -m)
case "$uname_s/$uname_m" in
  Darwin/arm64)   PLAT="macos-arm64";  APP_SRC=mozilla-central/obj-weles/dist/Nightly.app   ;;
  Darwin/x86_64)  PLAT="macos-x86_64"; APP_SRC=mozilla-central/obj-weles/dist/Nightly.app   ;;
  Linux/x86_64)   PLAT="linux-x86_64"; APP_SRC=mozilla-central/obj-weles/dist/firefox       ;;
  *) echo "ERROR: unsupported platform $uname_s/$uname_m" >&2; exit 1 ;;
esac

if [[ ! -e "$APP_SRC" ]]; then
  echo "ERROR: build output missing at $APP_SRC" >&2
  exit 1
fi

OUT="weles-firefox-${TAG}-${PLAT}.tar.gz"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [[ "$uname_s" == "Darwin" ]]; then
  cp -RL "$APP_SRC" "$STAGE/Firefox.app"
  # Rename bundle display so findCustomBrowser finds Firefox.app/.../firefox
  /usr/bin/plutil -replace CFBundleName -string "WelesFirefox" "$STAGE/Firefox.app/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleDisplayName -string "Weles Firefox" "$STAGE/Firefox.app/Contents/Info.plist"
  tar -C "$STAGE" -czf "$OUT" Firefox.app
else
  cp -RL "$APP_SRC" "$STAGE/firefox"
  tar -C "$STAGE" -czf "$OUT" firefox
fi

SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')
echo "=============================================="
echo "artifact : $OUT"
echo "tag      : $TAG"
echo "platform : $PLAT"
echo "sha256   : $SHA"
echo "=============================================="
echo "Upload as: weles-firefox-${TAG}-${PLAT}.tar.gz"
echo "to GitHub Release: firefox-${TAG}  on  wisent-ai/weles-firefox"
echo "Then set WELES_FIREFOX_RELEASE=firefox-${TAG} for weles/scripts/firefox/download.sh."
