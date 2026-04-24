# firefox-build

Sibling of `../chromium-build/`. Hosts the weles-patched Firefox source tree
and its build output. Consumed by `../weles/` via
`scripts/firefox/download.sh` (pulls the prebuilt tarball) or by pointing
`FIREFOX_PATH` at the local `dist/` output.

**The tree itself is NOT in this directory yet.** This scaffold lands first
so the build recipe has a home; cloning mozilla-central (~10 GB) and running
`./mach build` (4–8 h first time) happens in a dedicated session.

## What gets patched

Empirical audit in `../weles/scripts/firefox/prefs_audit.mjs` confirmed that
five of the six Chromium C++ surfaces are already achievable on stock Firefox
via `firefoxUserPrefs` — those do not need a fork. The remaining surfaces
that do require engine-level patches are tracked in
`../weles/scripts/firefox/PATCHING.md` Phase 2, and their `.patch` files land
in `./patches/` once written.

Current patch targets (all applied to gecko-dev@5836a062; verified `git apply --check`):

| Surface | Gecko file | Patch |
|---|---|---|
| `weles.fingerprint.*` pref registration | `modules/libpref/init/all.js` | `patches/0001-weles-prefs-register.patch` |
| `navigator.webdriver=false` short-circuit | `dom/base/Navigator.cpp` | `patches/0002-weles-navigator-webdriver.patch` |
| WebGL vendor/renderer raw (no sanitizer) | `dom/canvas/ClientWebGLContext.cpp` | `patches/0003-weles-webgl-vendor-renderer.patch` |
| `screen.width/height/availWidth/availHeight` | `dom/base/nsScreen.cpp` | `patches/0004-weles-nsScreen-overrides.patch` |
| `window.outerWidth/outerHeight/screenX/screenY` | `dom/base/nsGlobalWindowOuter.cpp` | `patches/0005-weles-window-outer-overrides.patch` |

The tree at `mozilla-central/` currently has all five patches applied. To
rebase onto a newer commit: `git checkout HEAD -- <files>` to revert,
`git fetch --depth 1 origin master && git reset --hard FETCH_HEAD`, then
`git apply patches/*.patch` again — hunks are small enough that fuzzy
apply (`git am -3`) works when context shifts.

## Build recipe (to run in a future session)

```bash
# One-time
git clone https://hg.mozilla.org/mozilla-central mozilla-central  # ~10 GB
cd mozilla-central
./mach bootstrap --no-interactive --application-choice=browser
# Pin the commit the patches target. Update PINNED_REV below when rebasing.
# PINNED_REV=<short-sha>
# hg update -r $PINNED_REV

# Apply weles patches (lands in this directory as we write them)
for p in ../patches/*.patch; do hg import --no-commit "$p"; done

# Build
cat > .mozconfig <<'EOF'
ac_add_options --enable-release
ac_add_options --disable-debug
ac_add_options --enable-optimize
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj-weles
EOF
./mach build

# Output
# obj-weles/dist/Nightly.app/  (macOS)  →  copy + rename to Weles.app if you want
#                                          the Dock label to be something other
#                                          than "Nightly". CFBundleName lives
#                                          in Contents/Info.plist.
```

## Consumed-by layout

```
~/.local/share/weles-firefox/
└── <version>-weles.N/
    └── Firefox.app/Contents/MacOS/firefox
```

`weles/src/session/wsession.ts::findCustomBrowser(browser)` (Phase-2
generalization of `findCustomChromium`) resolves this path when
`WSession.start({ browser: 'firefox' })` is called and a prebuilt binary
exists. If the path is empty and `browser === 'firefox'`, WSession falls
through to Playwright's bundled Firefox — which after Phase 1 carries the
pref/stub/scrub parity work and is safe to use for everything except the
five surfaces above.
