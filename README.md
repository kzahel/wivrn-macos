# WiVRn macOS Host

Minimal macOS packaging/build repo for an experimental WiVRn host.

The goal is to build and ship a small, understandable Mac host package that
contains:

- `wivrn-server-headless`
- the Monado OpenXR runtime used by WiVRn
- a pinned Khronos OpenXR loader for bundled probes and app-side testing
- a small Tauri controller app for status, logs, updates, and start/stop
- a signed `.app`, `.dmg`, and `.pkg` built by GitHub Actions

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
    OpenXR-SDK/
  desktop/
    tauri-app/
  build/
    wivrn/
    openxr-loader/
    probes/
  dist/
```

`third_party/`, `build/`, and `dist/` are generated/local directories and are
ignored by git.

## Prerequisites

- macOS on Apple Silicon
- Xcode Command Line Tools
- Homebrew packages:

```bash
brew install cmake ninja pkg-config
```

- Rust
- Node.js and pnpm

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

Build the pinned Khronos OpenXR loader:

```bash
scripts/build_openxr_loader.sh
```

Outputs:

- `build/openxr-loader/lib/libopenxr_loader.dylib`
- `build/openxr-loader/include/openxr/`

## Run Locally

After building:

```bash
build/wivrn/server/wivrn-server-headless --no-encrypt
```

Host speaker audio can be enabled explicitly:

```bash
build/wivrn/server/wivrn-server-headless --no-encrypt --enable-audio
```

For development builds, point local OpenXR apps at the generated runtime
manifest:

```bash
XR_RUNTIME_JSON="$PWD/build/wivrn/openxr_wivrn-dev.json" your-openxr-app
```

This is only a build-tree override. Installed apps should use the normal OpenXR
loader flow described below.

## OpenXR Probe Apps

This repo includes two small command-line OpenXR examples under `examples/`.
They are meant to validate the packaged host and runtime while staying separate
from the packaging logic.

- `openxr-runtime-probe` loads the OpenXR loader, creates an instance, asks for
  an HMD system, and prints runtime/system/view configuration details. This is
  the normal app discovery path and is the first thing to try after installing
  the package.
- `openxr-metal-frame-probe` is the carried-over Metal graphics probe. It
  loads the WiVRn/Monado runtime dylib directly, uses `XR_KHR_metal_enable`,
  creates stereo swapchains, renders simple test patterns, and submits
  projection frames.

Build the loader and probes:

```bash
scripts/build_openxr_probes.sh
```

Run the normal loader/discovery probe against a build-tree runtime:

```bash
XR_RUNTIME_JSON="$PWD/build/wivrn/openxr_wivrn-dev.json" \
  build/probes/openxr-runtime-probe
```

After installing the pkg, the same probe should work without `XR_RUNTIME_JSON`
because the installer registers WiVRn as the active OpenXR runtime. The probe
loads the repo-built loader from `build/openxr-loader/lib/` by default; set
`WIVRN_OPENXR_LOADER_PATH` to override it.

Run the Metal frame-submit probe against a build-tree runtime:

```bash
MONADO_OPENXR_RUNTIME_PATH="$PWD/build/wivrn/_deps/monado-build/src/xrt/targets/openxr/libopenxr_wivrn.dylib" \
WIVRN_OPENXR_METAL_PROBE_PATTERN=world-geometry \
WIVRN_OPENXR_METAL_PROBE_FRAMES=120 \
  build/probes/openxr-metal-frame-probe
```

Useful Metal probe patterns include `stereo-rg`, `solid-magenta`,
`geometry-quadrants`, `world-card`, `world-grid`, `world-grid-passthrough`, and
`world-geometry`.

## OpenXR Runtime Discovery

OpenXR applications do not discover WiVRn headsets directly. They link or load
the OpenXR loader, create an `XrInstance`, and ask the active runtime for a
head-mounted display system with `xrGetSystem`.

The intended macOS flow is:

1. The WiVRn Mac Host package installs the headless host and OpenXR runtime.
2. The installer registers WiVRn as the active OpenXR runtime.
3. An OpenXR app loads the OpenXR loader. On macOS there is no Apple-provided
   system loader, so apps should bundle or explicitly locate a Khronos loader.
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

This repo builds a pinned Khronos loader for its probes and packages that loader
inside the Tauri app resources. It does not install the loader globally into
`/usr/local/lib`; real macOS OpenXR apps should bundle/link a loader while using
the registered WiVRn runtime manifest for runtime selection.

## Current Feature State

The intended current working slice is:

- native Metal OpenXR runtime on macOS through the Monado fork
- `wivrn-server-headless` as the host process
- direct Quest connection using the stock WiVRn Quest APK
- stereo video streaming with VideoToolbox H.264 on Apple builds
- 6DoF tracking, controller input, and hand tracking through WiVRn's existing
  network path
- passthrough alpha stream support on the macOS video path
- optional host speaker audio to the headset with `--enable-audio`

## Known Feature Gaps

Known gaps compared to the Linux WiVRn server:

- **Foveated rendering/encoding:** real foveation is not active on macOS. The
  server sends identity foveation parameters so the Quest client does not
  inverse-foveate an image that was never foveated by the Metal compositor. This
  keeps geometry correct, but full-resolution frames must be encoded and fast
  head turns may show edge artifacts that Linux avoids with its foveated
  compositor path.
- **Quest microphone return:** speaker audio can be sent to the headset, but
  Quest microphone audio is not exposed to macOS apps as an input device.
  Linux-style `WiVRn(microphone)` parity likely needs a virtual CoreAudio input
  device or another explicit macOS input strategy.
- **Headset service discovery:** the installer registers the OpenXR runtime for
  local apps, but WiVRn's Linux Avahi service publication does not have a macOS
  Bonjour/mDNS equivalent yet. Quest connection may still require manual host
  selection or the current WiVRn pairing flow.
- **Desktop shell parity:** the Linux desktop shell, app launcher, and related
  desktop integration are not part of the current macOS host package.
- **Packaged host UX:** the Tauri app is an initial controller, not a polished
  menu bar app, pairing assistant, diagnostics view, or background supervisor.
- **Eye gaze tracking:** not implemented on the macOS path.
- **Metal swapchain synchronization:** the current synchronization path favors
  correctness over latency. A lower-latency MTLSharedEvent-style path is still
  future work.
- **Release hardening:** signing, notarization, dependency bundling policy, and
  release automation still need to be finalized before public binary releases.

## Package An App Bundle

Create the Tauri `.app` and `.dmg` bundle:

```bash
pnpm install --dir desktop/tauri-app
scripts/package_macos_app.sh
```

Outputs are under Tauri's bundle directory:

```text
desktop/tauri-app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/WiVRn Mac Host.app
desktop/tauri-app/src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/
```

The app bundle contains a Tauri controller UI, the headless server sidecar, and
the Monado OpenXR runtime artifacts. The controller can start, stop, restart,
show recent logs, expose the config path, and check for app updates.

## Build A PKG

Create a macOS installer package from the Tauri-built app:

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

GitHub Actions uses the same signing secret names as the JSTorrent Tauri app:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `ASC_API_KEY_P8_BASE64`
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`

Tagged releases use `v<version>` tags, create Tauri updater artifacts, and
upload the pkg alongside the Tauri app artifacts. The intended release flow is:

1. Build WiVRn and Monado.
2. Prepare Tauri sidecars and OpenXR resources.
3. Build and sign `WiVRn Mac Host.app`.
4. Build and sign a `.dmg`.
5. Build and sign a `.pkg`.
6. Upload release artifacts from GitHub Actions.
7. Publish Tauri updater metadata.

See [docs/tauri-packaging-plan.md](docs/tauri-packaging-plan.md) for the
JSTorrent-derived packaging plan.

## GitHub Actions

`.github/workflows/macos-build.yml` builds the headless host, builds the Tauri
app/DMG, wraps the app in a pkg, and uploads artifacts on a macOS runner.

Before using it for public releases, decide:

- whether binaries should bundle all dependent runtime libraries or use a
  stricter system dependency list
- whether updates that alter OpenXR registration should require a fresh pkg
  install or a privileged helper migration
