#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build_dir="${BUILD_DIR:-${repo_root}/build/wivrn}"
tauri_dir="${TAURI_APP_DIR:-${repo_root}/desktop/tauri-app}"
target_triple="${TARGET_TRIPLE:-$(rustc --print host-tuple)}"

host_bin="${WIVRN_HOST_BIN:-${build_dir}/server/wivrn-server-headless}"
runtime_dylib="${MONADO_OPENXR_RUNTIME_PATH:-${build_dir}/_deps/monado-build/src/xrt/targets/openxr/libopenxr_wivrn.dylib}"
loader_dylib="${OPENXR_LOADER_DYLIB:-${repo_root}/build/openxr-loader/lib/libopenxr_loader.dylib}"

sidecar_dir="${tauri_dir}/src-tauri/binaries"
resource_openxr_dir="${tauri_dir}/src-tauri/resources/openxr"

if [ ! -x "${host_bin}" ]; then
    echo "Missing host binary: ${host_bin}" >&2
    echo "Run scripts/build_macos_headless.sh first." >&2
    exit 1
fi

if [ ! -f "${runtime_dylib}" ]; then
    echo "Missing OpenXR runtime dylib: ${runtime_dylib}" >&2
    echo "Run scripts/build_macos_headless.sh first." >&2
    exit 1
fi

if [ ! -f "${loader_dylib}" ]; then
    echo "Missing OpenXR loader dylib: ${loader_dylib}" >&2
    echo "Run scripts/build_openxr_loader.sh first." >&2
    exit 1
fi

mkdir -p "${sidecar_dir}" "${resource_openxr_dir}"

cp "${host_bin}" "${sidecar_dir}/wivrn-server-headless-${target_triple}"
chmod +x "${sidecar_dir}/wivrn-server-headless-${target_triple}"

cp "${runtime_dylib}" "${resource_openxr_dir}/libopenxr_wivrn.dylib"
cp "${loader_dylib}" "${resource_openxr_dir}/libopenxr_loader.dylib"

cat >"${resource_openxr_dir}/openxr_wivrn.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "WiVRn Mac Host",
        "library_path": "./libopenxr_wivrn.dylib"
    }
}
EOF

echo "Prepared Tauri sidecar: ${sidecar_dir}/wivrn-server-headless-${target_triple}"
echo "Prepared Tauri OpenXR resources: ${resource_openxr_dir}"
