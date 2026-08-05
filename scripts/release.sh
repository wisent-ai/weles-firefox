#!/usr/bin/env bash
# Tarball the built weles-firefox into the shape scripts/firefox/download.sh
# expects from a GitHub Release (weles-firefox-<version>-<platform>.tar.gz).
#
# Run after build.sh completes. Output: ./weles-firefox-<version>-<plat>.tar.gz
# and its sha256. Uploading to a GitHub Release is operator-side.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
REPO="wisent-ai/weles-firefox"
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required to publish the candidate" >&2
  exit 1
fi
ACTOR="$(gh api user --jq .login)"
APPROVERS="$(gh variable get WELES_RELEASE_APPROVERS --repo "$REPO")"
if ! printf '%s\n' "$APPROVERS" | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fqx "$ACTOR"; then
  echo "ERROR: ${ACTOR:-current GitHub actor} is not an allowlisted Weles release operator" >&2
  exit 1
fi
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "ERROR: commit tracked Firefox release inputs before publishing" >&2
  exit 1
fi

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
  Darwin/arm64)   PLAT="darwin-arm64"; APP_SRC=mozilla-central/obj-weles/dist/Nightly.app; ENTRYPOINT="Firefox.app/Contents/MacOS/firefox" ;;
  Darwin/x86_64)  PLAT="darwin-x64"; APP_SRC=mozilla-central/obj-weles/dist/Nightly.app; ENTRYPOINT="Firefox.app/Contents/MacOS/firefox" ;;
  Linux/x86_64)   PLAT="linux-x64"; APP_SRC=mozilla-central/obj-weles/dist/firefox; ENTRYPOINT="firefox/firefox" ;;
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

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUT" > "$OUT.sha256"
else
  sha256sum "$OUT" > "$OUT.sha256"
fi
SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
PATCH_TREE="$(git -C "$REPO_ROOT" rev-parse HEAD:patches)"
CAPABILITIES_SHA256="$(openssl dgst -sha256 -r "$REPO_ROOT/browser-capabilities.json" | awk '{print $1}')"
FINAL_TAG="firefox-$TAG"
CANDIDATE_TAG="candidate-$FINAL_TAG-${SOURCE_REVISION:0:8}"
jq -n \
  --arg schema "weles.browser-candidate.v1" \
  --arg engine "firefox" \
  --arg finalTag "$FINAL_TAG" \
  --arg candidateTag "$CANDIDATE_TAG" \
  --arg sourceRevision "$SOURCE_REVISION" \
  --arg patchTree "$PATCH_TREE" \
  --arg platform "$PLAT" \
  --arg entrypoint "$ENTRYPOINT" \
  --arg artifact "$OUT" \
  --arg artifactSha256 "$(awk 'NF { print $1; exit }' "$OUT.sha256")" \
  --arg capabilitiesSha256 "$CAPABILITIES_SHA256" \
  '{schema: $schema, engine: $engine, finalTag: $finalTag, candidateTag: $candidateTag, sourceRevision: $sourceRevision, patchTree: $patchTree, platform: $platform, entrypoint: $entrypoint, artifact: $artifact, artifactSha256: $artifactSha256, capabilitiesSha256: $capabilitiesSha256, status: "candidate"}' \
  > release-metadata.json
cp "$REPO_ROOT/browser-capabilities.json" browser-capabilities.release.json
SHA="$(awk 'NF{print $1; exit}' "$OUT.sha256")"
echo "=============================================="
echo "artifact : $OUT"
echo "checksum : $OUT.sha256"
echo "candidate: $CANDIDATE_TAG"
echo "platform : $PLAT"
echo "sha256   : $SHA"
echo "=============================================="
gh release create "$CANDIDATE_TAG" \
  "$OUT" "$OUT.sha256" browser-capabilities.release.json release-metadata.json \
  --repo "$REPO" --target "$SOURCE_REVISION" --prerelease \
  --title "$CANDIDATE_TAG" \
  --notes "Candidate bytes for $FINAL_TAG. Production promotion must reuse these exact bytes and attach Probierz evidence bound to the artifact SHA-256."
printf '%s\n' "$CANDIDATE_TAG"
