#!/usr/bin/env bash
# package-release.sh -- build a macOS app bundle and DMG for Dia.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

readonly APP_NAME="Dia"
readonly APP_BUNDLE_NAME="${APP_NAME}.app"
readonly FRAMEWORKS_DIR_NAME="Frameworks"
readonly RESOURCES_DIR_NAME="Resources"
readonly MACOS_DIR_NAME="MacOS"
readonly ICON_ASSETS_DIR="${REPO_ROOT}/build/linux"
readonly INFO_TEMPLATE_PATH="${SCRIPT_DIR}/Info.plist.template"
readonly ENTITLEMENTS_PATH="${SCRIPT_DIR}/Dia.entitlements"
readonly RUNTIME_DYLIB_NAME="libdia_core.dylib"

VERSION=""
APP_BINARY_PATH=""
CORE_DYLIB_PATH="${REPO_ROOT}/core/target/release/${RUNTIME_DYLIB_NAME}"
OUTPUT_DIR="${REPO_ROOT}/dist"
SIGN_IDENTITY=""
APPLE_ID=""
APPLE_ID_PASSWORD=""
APPLE_TEAM_ID=""
WORK_DIR=""

usage() {
  cat <<'EOF'
Usage: package-release.sh --version <version> [options]

Options:
  --app-binary <path>         Path to the built macOS executable
  --core-dylib <path>         Path to libdia_core.dylib
  --output-dir <path>         Directory where release artifacts are written
  --sign-identity <identity>  Developer ID Application identity for codesign
  --apple-id <value>          Apple ID for notarization
  --apple-id-password <value> App-specific password for notarization
  --apple-team-id <value>     Apple team ID for notarization
  -h, --help                  Show this help message
EOF
}

require_file() {
  local path="${1}"

  if [[ ! -f "${path}" ]]; then
    printf 'missing required file: %s\n' "${path}" >&2
    exit 1
  fi
}

resolve_file_path() {
  local path="${1}"
  local parent_dir

  parent_dir="$(cd "$(dirname "${path}")" && pwd)"
  printf '%s/%s\n' "${parent_dir}" "$(basename "${path}")"
}

resolve_dir_path() {
  local path="${1}"

  mkdir -p "${path}"
  (
    cd "${path}"
    pwd
  )
}

default_app_binary_path() {
  local arch="${1}"

  printf '%s\n' "${REPO_ROOT}/macos-ui/.build/${arch}-apple-macosx/release/${APP_NAME}"
}

platform_arch() {
  local raw_arch
  raw_arch="$(uname -m)"

  case "${raw_arch}" in
    arm64|x86_64)
      printf '%s\n' "${raw_arch}"
      ;;
    *)
      printf 'unsupported macOS architecture: %s\n' "${raw_arch}" >&2
      exit 1
      ;;
  esac
}

require_full_notarization_config() {
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    if [[ -n "${APPLE_ID}" || -n "${APPLE_ID_PASSWORD}" || -n "${APPLE_TEAM_ID}" ]]; then
      printf 'notarization requires --sign-identity\n' >&2
      exit 1
    fi
    return
  fi

  if [[ -n "${APPLE_ID}" || -n "${APPLE_ID_PASSWORD}" || -n "${APPLE_TEAM_ID}" ]]; then
    if [[ -z "${APPLE_ID}" || -z "${APPLE_ID_PASSWORD}" || -z "${APPLE_TEAM_ID}" ]]; then
      printf 'apple notarization requires Apple ID, password, and team ID\n' >&2
      exit 1
    fi
  fi
}

bundle_version() {
  python3 -c 'import re, sys; value = sys.argv[1]; parts = re.findall(r"\d+", value); print(".".join(parts[:3]) if parts else "1")' \
    "${VERSION}"
}

write_info_plist() {
  local destination="${1}"
  local release_version
  local build_number

  release_version="${VERSION}"
  build_number="$(bundle_version)"

  python3 -c 'import pathlib, sys; template = pathlib.Path(sys.argv[1]).read_text(); template = template.replace("__VERSION__", sys.argv[2]).replace("__BUNDLE_VERSION__", sys.argv[3]); pathlib.Path(sys.argv[4]).write_text(template)' \
    "${INFO_TEMPLATE_PATH}" \
    "${release_version}" \
    "${build_number}" \
    "${destination}"

  plutil -lint "${destination}" >/dev/null
}

build_icon_file() {
  local destination="${1}"
  local iconset_dir="${WORK_DIR}/Dia.iconset"

  require_file "${ICON_ASSETS_DIR}/icon-16x16.png"
  require_file "${ICON_ASSETS_DIR}/icon-32x32.png"
  require_file "${ICON_ASSETS_DIR}/icon-64x64.png"
  require_file "${ICON_ASSETS_DIR}/icon-128x128.png"
  require_file "${ICON_ASSETS_DIR}/icon-256x256.png"
  require_file "${ICON_ASSETS_DIR}/icon-512x512.png"

  rm -rf "${iconset_dir}"
  mkdir -p "${iconset_dir}"

  install -m644 "${ICON_ASSETS_DIR}/icon-16x16.png" \
    "${iconset_dir}/icon_16x16.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-32x32.png" \
    "${iconset_dir}/icon_16x16@2x.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-32x32.png" \
    "${iconset_dir}/icon_32x32.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-64x64.png" \
    "${iconset_dir}/icon_32x32@2x.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-128x128.png" \
    "${iconset_dir}/icon_128x128.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-256x256.png" \
    "${iconset_dir}/icon_128x128@2x.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-256x256.png" \
    "${iconset_dir}/icon_256x256.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-512x512.png" \
    "${iconset_dir}/icon_256x256@2x.png"
  install -m644 "${ICON_ASSETS_DIR}/icon-512x512.png" \
    "${iconset_dir}/icon_512x512.png"
  sips -z 1024 1024 "${ICON_ASSETS_DIR}/icon-512x512.png" \
    --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "${iconset_dir}" -o "${destination}"
}

linked_core_install_name() {
  local executable_path="${1}"

  python3 -c 'import subprocess, sys; output = subprocess.check_output(["otool", "-L", sys.argv[1]], text=True); lines = output.splitlines()[1:]; matches = [line.strip().split(" ", 1)[0] for line in lines if "libdia_core.dylib" in line];
if len(matches) != 1:
    raise SystemExit(f"expected one libdia_core.dylib dependency, found {len(matches)}")
print(matches[0])' \
    "${executable_path}"
}

build_app_bundle() {
  local work_dir="${1}"
  local app_bundle_path="${work_dir}/${APP_BUNDLE_NAME}"
  local contents_dir="${app_bundle_path}/Contents"
  local macos_dir="${contents_dir}/${MACOS_DIR_NAME}"
  local frameworks_dir="${contents_dir}/${FRAMEWORKS_DIR_NAME}"
  local resources_dir="${contents_dir}/${RESOURCES_DIR_NAME}"
  local bundled_dylib_path="${frameworks_dir}/${RUNTIME_DYLIB_NAME}"
  local current_install_name

  mkdir -p "${macos_dir}" "${frameworks_dir}" "${resources_dir}"

  install -m755 "${APP_BINARY_PATH}" "${macos_dir}/${APP_NAME}"
  install -m755 "${CORE_DYLIB_PATH}" "${bundled_dylib_path}"
  build_icon_file "${resources_dir}/iconfile.icns"
  write_info_plist "${contents_dir}/Info.plist"

  install_name_tool -id "@rpath/${RUNTIME_DYLIB_NAME}" "${bundled_dylib_path}"
  current_install_name="$(linked_core_install_name "${APP_BINARY_PATH}")"
  install_name_tool -change "${current_install_name}" \
    "@rpath/${RUNTIME_DYLIB_NAME}" \
    "${macos_dir}/${APP_NAME}"
  install_name_tool -add_rpath "@executable_path/../${FRAMEWORKS_DIR_NAME}" \
    "${macos_dir}/${APP_NAME}"

  printf '%s\n' "${app_bundle_path}"
}

sign_app_bundle() {
  local app_bundle_path="${1}"
  local contents_dir="${app_bundle_path}/Contents"
  local executable_path="${contents_dir}/${MACOS_DIR_NAME}/${APP_NAME}"
  local dylib_path="${contents_dir}/${FRAMEWORKS_DIR_NAME}/${RUNTIME_DYLIB_NAME}"

  if [[ -z "${SIGN_IDENTITY}" ]]; then
    return
  fi

  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${dylib_path}"
  codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS_PATH}" \
    --sign "${SIGN_IDENTITY}" \
    "${executable_path}"
  codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS_PATH}" \
    --sign "${SIGN_IDENTITY}" \
    "${app_bundle_path}"
  codesign --verify --deep --strict --verbose=2 "${app_bundle_path}"
}

build_dmg() {
  local app_bundle_path="${1}"
  local dmg_path="${2}"
  local dmg_staging_dir="${3}"

  rm -rf "${dmg_staging_dir}"
  mkdir -p "${dmg_staging_dir}"

  cp -R "${app_bundle_path}" "${dmg_staging_dir}/${APP_BUNDLE_NAME}"
  ln -s /Applications "${dmg_staging_dir}/Applications"

  hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${dmg_staging_dir}" \
    -ov \
    -format UDZO \
    "${dmg_path}"
}

sign_dmg() {
  local dmg_path="${1}"

  if [[ -z "${SIGN_IDENTITY}" ]]; then
    return
  fi

  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${dmg_path}"
}

notarize_dmg() {
  local dmg_path="${1}"

  if [[ -z "${APPLE_ID}" ]]; then
    return
  fi

  xcrun notarytool submit "${dmg_path}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_ID_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" \
    --wait
  xcrun stapler staple "${dmg_path}"
}

parse_args() {
  while (( $# > 0 )); do
    case "${1}" in
      --version)
        VERSION="${2}"
        shift 2
        ;;
      --app-binary)
        APP_BINARY_PATH="${2}"
        shift 2
        ;;
      --core-dylib)
        CORE_DYLIB_PATH="${2}"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="${2}"
        shift 2
        ;;
      --sign-identity)
        SIGN_IDENTITY="${2}"
        shift 2
        ;;
      --apple-id)
        APPLE_ID="${2}"
        shift 2
        ;;
      --apple-id-password)
        APPLE_ID_PASSWORD="${2}"
        shift 2
        ;;
      --apple-team-id)
        APPLE_TEAM_ID="${2}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'unknown argument: %s\n' "${1}" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "${VERSION}" ]]; then
    printf '--version is required\n' >&2
    usage >&2
    exit 1
  fi
}

binary_arch() {
  local binary_path="${1}"
  local archs

  archs="$(lipo -info "${binary_path}" 2>&1)"
  if [[ "${archs}" == *"architecture: arm64"* && "${archs}" == *"architecture: x86_64"* ]]; then
    printf 'universal\n'
  elif [[ "${archs}" == *"architecture: arm64"* ]]; then
    printf 'arm64\n'
  elif [[ "${archs}" == *"architecture: x86_64"* ]]; then
    printf 'x86_64\n'
  else
    printf 'unknown\n'
  fi
}

main() {
  local arch
  local release_name
  local dmg_path
  local app_bundle_path
  local dmg_staging_dir

  parse_args "$@"

  arch="$(platform_arch)"

  if [[ -z "${APP_BINARY_PATH}" ]]; then
    APP_BINARY_PATH="$(default_app_binary_path "${arch}")"
  fi

  APP_BINARY_PATH="$(resolve_file_path "${APP_BINARY_PATH}")"
  CORE_DYLIB_PATH="$(resolve_file_path "${CORE_DYLIB_PATH}")"
  OUTPUT_DIR="$(resolve_dir_path "${OUTPUT_DIR}")"
  require_full_notarization_config

  require_file "${APP_BINARY_PATH}"
  require_file "${CORE_DYLIB_PATH}"
  require_file "${INFO_TEMPLATE_PATH}"
  require_file "${ENTITLEMENTS_PATH}"

  arch="$(binary_arch "${APP_BINARY_PATH}")"
  release_name="dia-${VERSION}-macos-${arch}"
  dmg_path="${OUTPUT_DIR}/${release_name}.dmg"

  rm -f "${dmg_path}"

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dia-macos-release.XXXXXX")"
  trap 'if [[ -n "${WORK_DIR}" ]]; then rm -rf "${WORK_DIR}"; fi' EXIT

  app_bundle_path="$(build_app_bundle "${WORK_DIR}")"
  sign_app_bundle "${app_bundle_path}"

  dmg_staging_dir="${WORK_DIR}/dmg"
  build_dmg "${app_bundle_path}" "${dmg_path}" "${dmg_staging_dir}"
  sign_dmg "${dmg_path}"
  notarize_dmg "${dmg_path}"

  printf 'created macOS release artifact: %s\n' "${dmg_path}"
}

main "$@"
