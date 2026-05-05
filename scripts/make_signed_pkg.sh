#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

dist_dir="${DIST_DIR:-${repo_root}/dist}"
tauri_dir="${TAURI_APP_DIR:-${repo_root}/desktop/tauri-app}"
target_triple="${TARGET_TRIPLE:-$(rustc --print host-tuple)}"
version="${VERSION:-}"
arch="${ARCH:-}"
app_dir="${APP_PATH:-${tauri_dir}/src-tauri/target/${target_triple}/release/bundle/macos/WiVRn Mac Host.app}"
codesign_identity="${CODESIGN_IDENTITY:-}"
installer_identity="${INSTALLER_IDENTITY:-}"

if [ -z "${version}" ]; then
    version="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "${tauri_dir}/src-tauri/tauri.conf.json" | head -1)"
fi

if [ -z "${version}" ]; then
    echo "Could not determine package version." >&2
    exit 1
fi

if [ -z "${arch}" ]; then
    case "${target_triple}" in
        aarch64-apple-darwin|arm64-apple-darwin)
            arch="aarch64"
            ;;
        x86_64-apple-darwin)
            arch="x64"
            ;;
        *)
            arch="${target_triple}"
            ;;
    esac
fi

pkg_path="${PKG_PATH:-${dist_dir}/WiVRn_Mac_Host_${version}_${arch}.pkg}"

if [ ! -d "${app_dir}" ]; then
    "${repo_root}/scripts/package_macos_app.sh"
fi

if [ ! -d "${app_dir}" ]; then
    echo "Missing app bundle: ${app_dir}" >&2
    exit 1
fi

mkdir -p "${dist_dir}"

if [ -n "${codesign_identity}" ]; then
    echo "Signing app with: ${codesign_identity}"
    codesign --force --deep --options runtime --timestamp --sign "${codesign_identity}" "${app_dir}"
elif codesign --verify --deep --strict "${app_dir}" >/dev/null 2>&1; then
    echo "App already has a valid deep signature."
else
    echo "No CODESIGN_IDENTITY set; applying ad-hoc app signature."
    codesign --force --deep --sign - "${app_dir}"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

pkgroot="${work_dir}/pkgroot"
component_pkg="${work_dir}/wivrn-macos-host-component.pkg"
unsigned_pkg="${work_dir}/wivrn-macos-host-unsigned.pkg"

mkdir -p "${pkgroot}/Applications"
cp -R "${app_dir}" "${pkgroot}/Applications/WiVRn Mac Host.app"

pkgbuild \
    --root "${pkgroot}" \
    --identifier dev.xrremote.wivrn-macos-host \
    --version "${version}" \
    --install-location / \
    --scripts "${repo_root}/scripts/pkg" \
    "${component_pkg}"

cat >"${work_dir}/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>WiVRn Mac Host</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="WiVRn Mac Host">
        <pkg-ref id="dev.xrremote.wivrn-macos-host"/>
    </choice>
    <pkg-ref id="dev.xrremote.wivrn-macos-host" version="${version}" onConclusion="none">wivrn-macos-host-component.pkg</pkg-ref>
</installer-gui-script>
EOF

rm -f "${pkg_path}"

productbuild \
    --distribution "${work_dir}/distribution.xml" \
    --package-path "${work_dir}" \
    "${unsigned_pkg}"

if [ -n "${installer_identity}" ]; then
    echo "Signing installer with: ${installer_identity}"
    productsign --sign "${installer_identity}" "${unsigned_pkg}" "${pkg_path}"
else
    cp "${unsigned_pkg}" "${pkg_path}"
fi

echo "Created ${pkg_path}"
