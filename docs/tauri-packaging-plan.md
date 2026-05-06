# Tauri Packaging Plan

This repo should use the same release shape as the JSTorrent Tauri app, but
with WiVRn-specific installer responsibilities.

## Reference Pattern From JSTorrent

The working reference is `~/code/jstorrent/desktop/tauri-app`.

Important pieces in that repo:

- `desktop/tauri-app/src-tauri/tauri.conf.json`
  - uses Tauri v2
  - sets `bundle.targets` to `all`
  - sets `bundle.createUpdaterArtifacts` to `true`
  - uses `bundle.externalBin` to include native sidecar binaries
  - configures the Tauri updater plugin
- `.github/workflows/tauri-app-ci.yml`
  - sets up Node, pnpm, and Rust
  - builds sidecar binaries before the Tauri build
  - uses `tauri-apps/tauri-action@v0`
  - uses `includeUpdaterJson` for tagged releases
  - uses the same signing/notarization secret names listed below
  - builds a separate macOS `.pkg` after the Tauri `.app` exists
- `desktop/tauri-app/scripts/build-macos-pkg.sh`
  - wraps the Tauri-built `.app` in a pkg
  - passes pkg scripts to `pkgbuild`
  - signs with `INSTALLER_IDENTITY` when present
- `desktop/tauri-app/installers/macos/scripts/postinstall`
  - performs system/user registration that a plain DMG drag install cannot do

The key lesson is that the DMG and pkg are both useful:

- The DMG is the normal Tauri/macOS drag-install artifact.
- The pkg is the system setup artifact when install-time registration is needed.
- Tauri updater handles app-level updates from updater artifacts.
- The pkg remains necessary when an install or migration must write global
  registration files.

## WiVRn macOS Target Shape

The WiVRn macOS app should be a Tauri controller around the existing headless
host, not a port of the Linux desktop shell.

The app bundle should contain:

- the Tauri UI/controller executable
- `wivrn-server-headless` as a Tauri sidecar
- `libopenxr_wivrn.dylib` as an app resource
- pinned Khronos `libopenxr_loader.dylib` as an app resource for bundled
  probes and diagnostics
- a bundled OpenXR runtime manifest for development/debug visibility

The UI should provide:

- current server running/stopped state
- start, stop, and restart controls
- an audio toggle for `--enable-audio`
- a no-encryption toggle for local testing
- the config file path
- recent server logs
- a check/install update action through the Tauri updater plugin

The headless server remains responsible for the WiVRn session. The Tauri app is
only the supervisor and user-facing control surface.

## Installer Responsibilities

The pkg should install:

- `/Applications/WiVRn Mac Host.app`

The pkg postinstall should register the OpenXR runtime:

```text
/usr/local/share/openxr/1/openxr_wivrn.json
/usr/local/share/openxr/1/active_runtime.<abi>.json -> openxr_wivrn.json
```

That mirrors the current script-based package and keeps local OpenXR apps on
the normal loader path. A plain DMG install can still be useful, but it cannot
perform this system registration step on its own.

The pkg should not install `libopenxr_loader.dylib` globally into
`/usr/local/lib`. On macOS, OpenXR apps should bundle or explicitly locate a
Khronos loader. WiVRn's package should provide one for its own tools and probes
while owning runtime registration separately.

## Signing And Notarization Secrets

Use the same GitHub secret names as JSTorrent so the environment setup can be
copied across:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `ASC_API_KEY_P8_BASE64`
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`

The checked-in updater public key in `desktop/tauri-app/src-tauri/tauri.conf.json`
currently matches the JSTorrent updater key. If this app gets its own Tauri
updater signing key, update that `pubkey` at the same time the corresponding
private key is installed as `TAURI_SIGNING_PRIVATE_KEY`.

The workflow should derive:

- `APPLE_CERTIFICATE` from `MACOS_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD` from `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY` from the Developer ID Application identity
- `APPLE_API_KEY_PATH` from the decoded App Store Connect private key
- `INSTALLER_IDENTITY` from the Developer ID Installer identity

Current default identities are intentionally aligned with the JSTorrent
workflow:

```text
Developer ID Application: Kyle Graehl (VD7BYQ6ABM)
Developer ID Installer: Kyle Graehl (VD7BYQ6ABM)
```

If a different certificate is used, update the workflow identity strings or pass
the corresponding environment values.

## Release Flow

For normal CI:

1. Check out this packaging repo.
2. Install Homebrew build dependencies.
3. Bootstrap WiVRn and Monado source checkouts.
4. Build `wivrn-server-headless` and `openxr_wivrn`.
5. Copy sidecar/resources into `desktop/tauri-app/src-tauri`.
6. Build the Tauri app and DMG.
7. Wrap the Tauri app in a pkg.
8. Upload CI artifacts.

For tagged releases:

1. Run the same build.
2. Let Tauri produce updater artifacts and `latest.json`.
3. Sign/notarize the app/DMG through Tauri when secrets are present.
4. Sign/notarize/staple the pkg when installer secrets are present.
5. Upload the pkg to the GitHub release alongside the Tauri artifacts.

Release tags should use `v<version>` for this repo, for example `v0.1.0`.

## Later Work

- Add Bonjour/mDNS `_wivrn._tcp` publication to the headless host or a tiny
  supervisor helper so the Quest can auto-discover the Mac host.
- Decide whether updates that change OpenXR registration should prompt users to
  run the pkg again or install a privileged helper.
- Add a LaunchAgent option if background startup becomes desirable.
