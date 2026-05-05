#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source_root="${SOURCE_ROOT:-${repo_root}/third_party}"
wivrn_dir="${WIVRN_SOURCE_DIR:-${source_root}/wivrn}"
monado_dir="${MONADO_SOURCE_DIR:-${source_root}/monado}"
build_dir="${BUILD_DIR:-${repo_root}/build/wivrn}"
build_type="${CMAKE_BUILD_TYPE:-RelWithDebInfo}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_dir() {
    if [ ! -d "$1" ]; then
        echo "Missing directory: $1" >&2
        echo "Run scripts/bootstrap_sources.sh or set WIVRN_SOURCE_DIR / MONADO_SOURCE_DIR." >&2
        exit 1
    fi
}

need_cmd cmake
need_cmd ninja
need_dir "${wivrn_dir}"
need_dir "${monado_dir}"

echo "WiVRn source:  ${wivrn_dir}"
echo "Monado source: ${monado_dir}"
echo "Build dir:     ${build_dir}"
echo "Build type:    ${build_type}"

cmake \
    -S "${wivrn_dir}" \
    -B "${build_dir}" \
    -G Ninja \
    -DWIVRN_MONADO_SOURCE_DIR="${monado_dir}" \
    -DCMAKE_BUILD_TYPE="${build_type}"

cmake --build "${build_dir}" --target wivrn-server-headless openxr_wivrn

echo
echo "Built:"
echo "  ${build_dir}/server/wivrn-server-headless"
echo "  ${build_dir}/_deps/monado-build/src/xrt/targets/openxr/libopenxr_wivrn.dylib"
echo "  ${build_dir}/openxr_wivrn-dev.json"

