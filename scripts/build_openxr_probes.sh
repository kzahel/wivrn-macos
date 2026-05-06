#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source_root="${SOURCE_ROOT:-${repo_root}/third_party}"
default_monado_dir="${source_root}/monado"
openxr_loader_dir="${OPENXR_LOADER_OUTPUT_DIR:-${repo_root}/build/openxr-loader}"
if [ -n "${MONADO_SOURCE_DIR:-}" ]; then
    monado_dir="${MONADO_SOURCE_DIR}"
elif [ -d "${default_monado_dir}/src/external/openxr_includes/openxr" ]; then
    monado_dir="${default_monado_dir}"
elif [ -d "${repo_root}/../monado/src/external/openxr_includes/openxr" ]; then
    monado_dir="${repo_root}/../monado"
else
    monado_dir="${default_monado_dir}"
fi
build_dir="${PROBE_BUILD_DIR:-${repo_root}/build/probes}"
openxr_sdk_include_dir="${openxr_loader_dir}/include"
monado_include_dir="${monado_dir}/src/external/openxr_includes"
if [ "${SKIP_OPENXR_LOADER_BUILD:-0}" != "1" ]; then
    "${repo_root}/scripts/build_openxr_loader.sh"
fi
if [ -d "${openxr_sdk_include_dir}/openxr" ]; then
    include_dir="${openxr_sdk_include_dir}"
else
    include_dir="${monado_include_dir}"
fi

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_dir() {
    if [ ! -d "$1" ]; then
        echo "Missing directory: $1" >&2
        echo "Run scripts/bootstrap_sources.sh or set MONADO_SOURCE_DIR." >&2
        exit 1
    fi
}

need_cmd clang
need_dir "${include_dir}/openxr"

mkdir -p "${build_dir}"

common_flags=(
    -I "${include_dir}"
    -Wall
    -Wextra
    -Wpedantic
)

echo "Monado headers: ${include_dir}"
echo "Probe build dir: ${build_dir}"

clang \
    "${common_flags[@]}" \
    -std=c11 \
    "${repo_root}/examples/openxr-runtime-probe/openxr_runtime_probe.c" \
    -o "${build_dir}/openxr-runtime-probe"

clang \
    "${common_flags[@]}" \
    -std=gnu11 \
    -fobjc-arc \
    -framework Foundation \
    -framework Metal \
    "${repo_root}/examples/openxr-metal-frame-probe/src/openxr_metal_frame_probe.m" \
    -o "${build_dir}/openxr-metal-frame-probe"

echo
echo "Built OpenXR probes:"
echo "  ${build_dir}/openxr-runtime-probe"
echo "  ${build_dir}/openxr-metal-frame-probe"
