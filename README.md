# WiVRn macOS Host

Minimal macOS packaging/build repo for an experimental WiVRn host.

The goal is to build and ship a small, understandable Mac host package that
contains:

- `wivrn-server-headless`
- the Monado OpenXR runtime used by WiVRn
- enough launcher/packaging glue to run on macOS
- eventually, a signed `.app` and `.pkg` built by GitHub Actions

## Current Shape

This repo is a thin build and packaging wrapper around two source checkouts:

- WiVRn fork: `combined` branch
- Monado fork: `combined` branch

The expected local layout is:

```text
wivrn-macos/
  third_party/
    wivrn/
    monado/
  build/
    wivrn/
  dist/
```

`third_party/`, `build/`, and `dist/` are generated/local directories and are
ignored by git.

## Prerequisites

- macOS on Apple Silicon
- Xcode Command Line Tools
- Homebrew packages:

```bash
brew install cmake ninja
```

For Quest testing you will also need Android platform tools and the stock WiVRn
Quest APK installed on the headset, but this repo does not include live headset
test automation.

## Bootstrap Sources

Clone the forked source checkouts:

```bash
scripts/bootstrap_sources.sh
```

Defaults:

- `WIVRN_REPO=git@github.com:kzahel/WiVRn.git`
- `MONADO_REPO=git@github.com:kzahel/monado.git`
- `WIVRN_BRANCH=combined`
- `MONADO_BRANCH=combined`

Override these if building from another fork:

```bash
WIVRN_REPO=https://github.com/YOUR_USER/WiVRn.git \
MONADO_REPO=https://github.com/YOUR_USER/monado.git \
  scripts/bootstrap_sources.sh
```

## Build

Build the macOS headless host and OpenXR runtime:

```bash
scripts/build_macos_headless.sh
```

Outputs:

- `build/wivrn/server/wivrn-server-headless`
- `build/wivrn/_deps/monado-build/src/xrt/targets/openxr/libopenxr_wivrn.dylib`
- `build/wivrn/openxr_wivrn-dev.json`

You can also point at existing checkouts:

```bash
WIVRN_SOURCE_DIR=/Users/kgraehl/code/reference/wivrn \
MONADO_SOURCE_DIR=/Users/kgraehl/code/monado \
  scripts/build_macos_headless.sh
```

## Run Locally

After building:

```bash
build/wivrn/server/wivrn-server-headless --no-encrypt
```

For development builds, point local OpenXR apps at the generated runtime
manifest:

```bash
XR_RUNTIME_JSON="$PWD/build/wivrn/openxr_wivrn-dev.json" your-openxr-app
```

This is only a build-tree override. Installed apps should use the normal OpenXR
loader flow described below.

## OpenXR Runtime Discovery

OpenXR applications do not discover WiVRn headsets directly. They link or load
the OpenXR loader, create an `XrInstance`, and ask the active runtime for a
head-mounted display system with `xrGetSystem`.

The intended macOS flow is:

1. The WiVRn Mac Host package installs the headless host and OpenXR runtime.
2. The installer registers WiVRn as the active OpenXR runtime.
3. An OpenXR app loads the OpenXR loader.
4. The loader reads the active runtime manifest and loads WiVRn's runtime.
5. WiVRn/Monado handles server IPC, network pairing, and headset availability.
6. The app sees either an available HMD system or a normal OpenXR unavailable
   error.

The package writes:

```text
/usr/local/share/openxr/1/openxr_wivrn.json
/usr/local/share/openxr/1/active_runtime.<abi>.json -> openxr_wivrn.json
```

For current Apple Silicon builds, `<abi>` is `aarch64`. Universal builds can
also use the undecorated `active_runtime.json` fallback. This mirrors the Linux
active-runtime convention while using the macOS runtime lookup path supported by
the Khronos OpenXR loader. `XR_RUNTIME_JSON` remains a developer escape hatch
for testing a non-installed build.

## Package An App Bundle

Create a minimal `.app` bundle:

```bash
scripts/package_macos_app.sh
```

Output:

```text
dist/WiVRn Mac Host.app
```

The app bundle contains the headless server and the Monado OpenXR runtime
artifacts. It is currently a packaging scaffold, not a polished launcher.

## Build A PKG

Create a macOS installer package:

```bash
scripts/make_signed_pkg.sh
```

Without signing identities this creates an unsigned package in `dist/`.
The package installs the app into `/Applications` and registers WiVRn as the
active OpenXR runtime for local OpenXR applications.

For local signing:

```bash
CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
INSTALLER_IDENTITY="Developer ID Installer: Example, Inc. (TEAMID)" \
  scripts/make_signed_pkg.sh
```

Notarization is not implemented yet. The intended future release flow is:

1. Build WiVRn and Monado.
2. Build `WiVRn Mac Host.app`.
3. Sign the app bundle.
4. Build and sign a `.pkg`.
5. Notarize and staple the package.
6. Upload release artifacts from GitHub Actions.

## GitHub Actions

`.github/workflows/macos-build.yml` is a starter workflow. It builds and
packages unsigned artifacts on a macOS runner.

Before using it for public releases, decide:

- whether the source forks are public or private
- how signing certificates are stored
- whether release jobs should notarize
- whether binaries should bundle all dependent runtime libraries or use a
  stricter system dependency list

## Non-Goals

- No headset validation scripts in this repo.
- No application-specific test harnesses.
- No product vision documents.
- No MIT rewrite experiment.
