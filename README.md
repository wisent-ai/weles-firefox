<!-- wisent-banner:start -->
<p align="center">
  <img src="assets/readme-banner.webp" alt="weles-firefox by Wisent" width="100%">
</p>
<!-- wisent-banner:end -->

<!-- wisent-readme-signals:start -->
[![Source](https://img.shields.io/badge/GitHub-Source-181717?logo=github)](https://github.com/wisent-ai/weles-firefox) [![Issues](https://img.shields.io/badge/GitHub-Issues-181717?logo=github)](https://github.com/wisent-ai/weles-firefox/issues) [![Wisent](https://img.shields.io/badge/Wisent-Website-0B0B0B)](https://wisent.ai) [![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/qRjpkthq54) [![LinkedIn](https://img.shields.io/badge/LinkedIn-Follow-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/company/wisent-ai/) [![X](https://img.shields.io/badge/X-Follow-000000?logo=x&logoColor=white)](https://x.com/wisentai) [![Enterprise](https://img.shields.io/badge/Enterprise-Book%20a%20call-0B0B0B?logo=calendly)](https://calendly.com/lbartoszcze)
<!-- wisent-readme-signals:end -->

# Patches for Firefox for the Weles AI Undetectable Browser Use Ecosystem

Published Firefox Artifact for Browser Use and Instructions How to Cook It.

This repository carries the Firefox patches, build instructions, verification,
and artifact-publishing process used by Weles. It is parallel to
[`wisent-ai/weles-chromium`](https://github.com/wisent-ai/weles-chromium).

This repository is the source of truth for the Gecko delta, its declared
capabilities, and the candidate-release contract. It does not vendor the
Firefox source tree or generated build output. A build uses a separate
`mozilla-central/` checkout pinned to the declared fork point.

## Upstream base

| | |
|---|---|
| Upstream version | **142.0a1** |
| Fork point | `5836a062` |
| Activation | `weles.fingerprint.*` preferences |

Update `browser-capabilities.json`, this table, and the patch series together
when rebasing onto a newer Firefox revision.

## What the patches do

The repository carries five patches:

| Patch | Surface | Gecko file |
|---|---|---|
| `0001-weles-prefs-register.patch` | Registers the `weles.fingerprint.*` preferences | `modules/libpref/init/all.js` |
| `0002-weles-navigator-webdriver.patch` | Overrides `navigator.webdriver` when explicitly configured | `dom/base/Navigator.cpp` |
| `0003-weles-webgl-vendor-renderer.patch` | Supplies configured WebGL vendor and renderer values | `dom/canvas/ClientWebGLContext.cpp` |
| `0004-weles-nsScreen-overrides.patch` | Supplies configured screen and available-screen geometry | `dom/base/nsScreen.cpp` |
| `0005-weles-window-outer-overrides.patch` | Supplies configured outer-window geometry and screen position | `dom/base/nsGlobalWindowOuter.cpp` |

The overrides are opt-in. Weles supplies the matching preferences for an
authorized browser session; an unconfigured build retains Firefox's normal
values. `browser-capabilities.json` is the machine-readable declaration used
by the release process.

## Repository layout

```text
patches/                    Reviewable Gecko patch series
browser-capabilities.json   Versioned capability declaration
weles_firefox/__main__.py    Apple-signed candidate packaging CLI
.github/workflows/release.yml
                            Candidate attestation and Weles dispatch
```

## Build input

The packager consumes an existing patched Firefox macOS build. The Gecko
checkout and Mozilla toolchain are not part of this repository. Build that
checkout with Mozilla's `mach build` after applying this repository's patch
series to the declared fork point. Packaging does not build or launch Firefox.

The former `scripts/build.sh`, `scripts/verify.mjs` and `scripts/release.sh`
were removed from this repository; they are not supported commands.

Build output:

```text
mozilla-central/obj-weles/dist/Nightly.app/Contents/MacOS/firefox  # macOS
mozilla-central/obj-weles/dist/bin/firefox                          # Linux
```

## Package a signed macOS candidate

The build host needs Python 3.11 or later, Wisent Products, and an available
Apple Development or Developer ID Application signing identity. Commit the
packaging inputs first. From this repository:

```sh
python3 -m weles_firefox package \
  --app /path/to/Nightly.app \
  --version 142.0a1-weles.6
```

Use the intended candidate revision instead of `6`. The command verifies the
input's Firefox version, copies it, preserves its `CFBundleIdentifier`, and
uses the [shared signing contract](https://stado.wisent.com/docs/signing) for
nested native code and the complete app. It verifies Apple trust with macOS
`codesign` before creating the archive and digest. The original app is unchanged.
The command does not launch a browser, request a privacy grant, reset TCC, or
publish a release.

Its JSON answer names the output directory under `artifacts/`, containing:

- the signed Firefox archive and SHA-256 checksum;
- `browser-capabilities.release.json`;
- `release-metadata.json` with the candidate tag, source revision, patch tree,
  platform, entrypoint, input executable digest and Apple designated requirement.

Missing signing tools or certificates remain errors. An incompatible input
version, a dirty producer checkout and an existing candidate directory are
refused. Ad-hoc signing is not an installation identity.

Publication retains the existing allowlisted-operator and candidate-attestation
workflow. It consumes these exact archive bytes; production promotion must
reuse them with verification evidence bound to their digest. Never re-sign a
checksum-selected browser installation in place.

## Consumption by Weles

Weles installs the promoted archive through its Stado release path under:

```text
~/.local/share/weles-firefox/<version>-weles.N/
└── Firefox.app/Contents/MacOS/firefox
```

Linux archives contain `firefox/firefox` instead. Weles launches only the
deployment-selected version whose checksum and local release receipt match;
absence or mismatch fails closed.

## Security and authorization

This source code does not authorize automation of any target. Weles workflows
remain bound to explicit origins, actions, credentials, and operator policy.
Report vulnerabilities through a
[private GitHub Security Advisory](https://github.com/wisent-ai/weles-firefox/security/advisories/new).
