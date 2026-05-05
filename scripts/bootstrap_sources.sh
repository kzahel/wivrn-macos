#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wivrn_repo="${WIVRN_REPO:-git@github.com:kzahel/WiVRn.git}"
monado_repo="${MONADO_REPO:-git@github.com:kzahel/monado.git}"
wivrn_branch="${WIVRN_BRANCH:-combined}"
monado_branch="${MONADO_BRANCH:-combined}"
source_root="${SOURCE_ROOT:-${repo_root}/third_party}"
wivrn_dir="${WIVRN_SOURCE_DIR:-${source_root}/wivrn}"
monado_dir="${MONADO_SOURCE_DIR:-${source_root}/monado}"

clone_or_report() {
    local repo="$1"
    local branch="$2"
    local dir="$3"
    local name="$4"

    if [ -d "${dir}/.git" ]; then
        echo "${name}: already exists at ${dir}"
        git -C "${dir}" status --short --branch
        return
    fi

    if [ -e "${dir}" ]; then
        echo "${name}: ${dir} exists but is not a git checkout" >&2
        exit 1
    fi

    echo "${name}: cloning ${repo} (${branch}) -> ${dir}"
    git clone --branch "${branch}" --single-branch "${repo}" "${dir}"
}

mkdir -p "${source_root}"
clone_or_report "${wivrn_repo}" "${wivrn_branch}" "${wivrn_dir}" "WiVRn"
clone_or_report "${monado_repo}" "${monado_branch}" "${monado_dir}" "Monado"

echo
echo "Source checkouts ready:"
echo "  WiVRn:  ${wivrn_dir}"
echo "  Monado: ${monado_dir}"

