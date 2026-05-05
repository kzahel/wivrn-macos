#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tauri_dir="${TAURI_APP_DIR:-${repo_root}/desktop/tauri-app}"
target_triple="${TARGET_TRIPLE:-$(rustc --print host-tuple)}"
bundles="${TAURI_BUNDLES:-app,dmg}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd pnpm
need_cmd rustc

"${repo_root}/scripts/prepare_tauri_sidecars.sh"

if [ ! -d "${tauri_dir}/node_modules" ]; then
    echo "Missing ${tauri_dir}/node_modules." >&2
    echo "Run: pnpm install --dir ${tauri_dir}" >&2
    exit 1
fi

extra_args=()
if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
    extra_args+=(--config '{"bundle":{"createUpdaterArtifacts":false}}')
fi

pnpm --dir "${tauri_dir}" tauri build --target "${target_triple}" --bundles "${bundles}" "${extra_args[@]}"

app_dir="${tauri_dir}/src-tauri/target/${target_triple}/release/bundle/macos/WiVRn Mac Host.app"
if [ ! -d "${app_dir}" ]; then
    echo "Tauri build completed but app was not found: ${app_dir}" >&2
    exit 1
fi

echo "Created ${app_dir}"
