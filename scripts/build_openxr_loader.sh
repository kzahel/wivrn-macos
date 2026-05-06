#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source_root="${SOURCE_ROOT:-${repo_root}/third_party}"
openxr_sdk_repo="${OPENXR_SDK_REPO:-https://github.com/KhronosGroup/OpenXR-SDK.git}"
openxr_sdk_tag="${OPENXR_SDK_TAG:-release-1.1.54}"
openxr_sdk_dir="${OPENXR_SDK_SOURCE_DIR:-${source_root}/OpenXR-SDK}"
build_dir="${OPENXR_LOADER_BUILD_DIR:-${repo_root}/build/openxr-loader-build}"
install_dir="${OPENXR_LOADER_INSTALL_DIR:-${repo_root}/build/openxr-loader-install}"
output_dir="${OPENXR_LOADER_OUTPUT_DIR:-${repo_root}/build/openxr-loader}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd cmake
need_cmd git
need_cmd ninja

if [ ! -d "${openxr_sdk_dir}/.git" ]; then
    if [ -e "${openxr_sdk_dir}" ]; then
        echo "OpenXR-SDK source exists but is not a git checkout: ${openxr_sdk_dir}" >&2
        exit 1
    fi

    mkdir -p "${source_root}"
    echo "OpenXR-SDK: cloning ${openxr_sdk_repo} (${openxr_sdk_tag}) -> ${openxr_sdk_dir}"
    git clone --branch "${openxr_sdk_tag}" --single-branch --depth 1 "${openxr_sdk_repo}" "${openxr_sdk_dir}"
else
    echo "OpenXR-SDK: using existing checkout at ${openxr_sdk_dir}"
    git -C "${openxr_sdk_dir}" status --short --branch
fi

cmake \
    -S "${openxr_sdk_dir}" \
    -B "${build_dir}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install_dir}" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_LOADER=ON \
    -DBUILD_API_LAYERS=OFF \
    -DBUILD_CONFORMANCE_TESTS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_TESTING=OFF

cmake --build "${build_dir}" --target install

loader_dylib="$(find "${install_dir}" "${build_dir}" -type f -name 'libopenxr_loader*.dylib' | sort | head -1)"
if [ -z "${loader_dylib}" ]; then
    echo "Could not find built libopenxr_loader.dylib under ${build_dir} or ${install_dir}" >&2
    exit 1
fi

mkdir -p "${output_dir}/lib"
cp -f "${loader_dylib}" "${output_dir}/lib/libopenxr_loader.dylib"

if command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id "@rpath/libopenxr_loader.dylib" "${output_dir}/lib/libopenxr_loader.dylib" 2>/dev/null || true
fi

rm -rf "${output_dir}/include"
cp -R "${openxr_sdk_dir}/include" "${output_dir}/include"

echo
echo "Built OpenXR loader:"
echo "  ${output_dir}/lib/libopenxr_loader.dylib"
echo "  ${output_dir}/include"
