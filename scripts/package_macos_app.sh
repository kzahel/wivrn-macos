#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build_dir="${BUILD_DIR:-${repo_root}/build/wivrn}"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
app_name="${APP_NAME:-WiVRn Mac Host}"
app_dir="${dist_dir}/${app_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
openxr_dir="${resources_dir}/openxr"

host_bin="${WIVRN_HOST_BIN:-${build_dir}/server/wivrn-server-headless}"
runtime_dylib="${MONADO_OPENXR_RUNTIME_PATH:-${build_dir}/_deps/monado-build/src/xrt/targets/openxr/libopenxr_wivrn.dylib}"

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

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${openxr_dir}"

cp "${host_bin}" "${macos_dir}/wivrn-server-headless"
cp "${runtime_dylib}" "${openxr_dir}/libopenxr_wivrn.dylib"

cat >"${openxr_dir}/openxr_wivrn.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "WiVRn Mac Host",
        "library_path": "./libopenxr_wivrn.dylib"
    }
}
EOF

cat >"${macos_dir}/WiVRn Mac Host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

app_macos_dir="$(cd "$(dirname "$0")" && pwd)"
exec "${app_macos_dir}/wivrn-server-headless" --no-encrypt "$@"
EOF
chmod +x "${macos_dir}/WiVRn Mac Host"

cat >"${contents_dir}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>WiVRn Mac Host</string>
  <key>CFBundleIdentifier</key>
  <string>dev.xrremote.wivrn-macos-host</string>
  <key>CFBundleName</key>
  <string>WiVRn Mac Host</string>
  <key>CFBundleDisplayName</key>
  <string>WiVRn Mac Host</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Created ${app_dir}"
