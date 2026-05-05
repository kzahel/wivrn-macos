#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

dist_dir="${DIST_DIR:-${repo_root}/dist}"
app_name="${APP_NAME:-WiVRn Mac Host}"
app_dir="${dist_dir}/${app_name}.app"
pkg_path="${PKG_PATH:-${dist_dir}/wivrn-macos-host.pkg}"
codesign_identity="${CODESIGN_IDENTITY:-}"
installer_identity="${INSTALLER_IDENTITY:-}"

"${repo_root}/scripts/package_macos_app.sh"

if [ -n "${codesign_identity}" ]; then
    echo "Signing app with: ${codesign_identity}"
    codesign --force --deep --options runtime --timestamp --sign "${codesign_identity}" "${app_dir}"
else
    echo "No CODESIGN_IDENTITY set; applying ad-hoc app signature."
    codesign --force --deep --sign - "${app_dir}"
fi

unsigned_pkg="${dist_dir}/wivrn-macos-host-unsigned.pkg"
rm -f "${unsigned_pkg}" "${pkg_path}"

pkgbuild \
    --component "${app_dir}" \
    --install-location /Applications \
    "${unsigned_pkg}"

if [ -n "${installer_identity}" ]; then
    echo "Signing installer with: ${installer_identity}"
    productsign --sign "${installer_identity}" "${unsigned_pkg}" "${pkg_path}"
    rm -f "${unsigned_pkg}"
else
    mv "${unsigned_pkg}" "${pkg_path}"
fi

echo "Created ${pkg_path}"

