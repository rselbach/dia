#!/usr/bin/env bash
# package-release.sh -- build Linux release artifacts for dia.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly APP_NAME="dia"
readonly DESKTOP_FILE_NAME="com.rselbach.dia.desktop"
readonly METAINFO_FILE_NAME="com.rselbach.dia.metainfo.xml"
readonly MERMAID_BUNDLE_NAME="mermaid.min.js"
readonly MERMAID_VERSION="11.13.0"
readonly MERMAID_URL="https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VERSION}/dist/mermaid.min.js"

VERSION=""
BINARY_PATH="${REPO_ROOT}/dia"
OUTPUT_DIR="${REPO_ROOT}/dist"

usage() {
  cat <<'EOF'
Usage: package-release.sh --version <version> [options]

Options:
  --binary <path>      Path to the built Linux UI binary
  --output-dir <path>  Directory where release artifacts will be written
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

copy_common_payload() {
  local staging_dir="${1}"

  mkdir -p "${staging_dir}/icons" "${staging_dir}/vendor"

  install -Dm755 "${BINARY_PATH}" "${staging_dir}/${APP_NAME}"
  install -Dm755 "${REPO_ROOT}/build/install.sh" \
    "${staging_dir}/install.sh"
  install -Dm644 "${REPO_ROOT}/build/${DESKTOP_FILE_NAME}" \
    "${staging_dir}/${DESKTOP_FILE_NAME}"
  install -Dm644 \
    "${REPO_ROOT}/build/${METAINFO_FILE_NAME}" \
    "${staging_dir}/${METAINFO_FILE_NAME}"
  install -Dm644 "${REPO_ROOT}/build/x-mermaid.xml" \
    "${staging_dir}/x-mermaid.xml"
  install -Dm644 "${REPO_ROOT}/build/icon.svg" \
    "${staging_dir}/icons/dia.svg"
  install -Dm644 "${REPO_ROOT}/vendor-js/${MERMAID_BUNDLE_NAME}" \
    "${staging_dir}/vendor/${MERMAID_BUNDLE_NAME}"

  local size
  for size in 16 32 48 64 128 256 512; do
    install -Dm644 "${REPO_ROOT}/build/icon-${size}x${size}.png" \
      "${staging_dir}/icons/dia-${size}x${size}.png"
  done
}

create_tarball() {
  local staging_dir="${1}"
  local output_file="${2}"
  local parent_dir
  local base_name

  parent_dir="$(dirname "${staging_dir}")"
  base_name="$(basename "${staging_dir}")"

  tar -C "${parent_dir}" -czf "${output_file}" "${base_name}"
}

package_native_packages() {
  local staging_dir="${1}"
  local deb_file="${2}"
  local rpm_file="${3}"
  local archlinux_file="${4}"
  local config_file="${OUTPUT_DIR}/nfpm.generated.yaml"

  python -c 'import pathlib, sys; template = pathlib.Path(sys.argv[1]).read_text(); template = template.replace("__VERSION__", sys.argv[2]).replace("__STAGING_DIR__", sys.argv[3]); pathlib.Path(sys.argv[4]).write_text(template)' \
    "${REPO_ROOT}/nfpm.yaml" \
    "${VERSION}" \
    "${staging_dir}" \
    "${config_file}"

  nfpm pkg --config "${config_file}" \
    --packager deb \
    --target "${deb_file}"

  nfpm pkg --config "${config_file}" \
    --packager rpm \
    --target "${rpm_file}"

  nfpm pkg --config "${config_file}" \
    --packager archlinux \
    --target "${archlinux_file}"

  rm -f "${config_file}"
}

webkit_runtime_dir() {
  local libdir
  libdir="$(pkg-config --variable=libdir webkitgtk-6.0)"
  printf '%s\n' "${libdir}/webkitgtk-6.0"
}

populate_appdir() {
  local appdir="${1}"
  local libdir_rel="${2}"
  local webkit_src_dir="${3}"
  local webkit_dst_dir="${appdir}/usr/${libdir_rel}/webkitgtk-6.0"

  install -Dm755 "${BINARY_PATH}" "${appdir}/usr/bin/${APP_NAME}"
  install -Dm755 "${REPO_ROOT}/build/AppRun" "${appdir}/AppRun"
  install -Dm644 "${REPO_ROOT}/build/${DESKTOP_FILE_NAME}" \
    "${appdir}/usr/share/applications/${DESKTOP_FILE_NAME}"
  install -Dm644 \
    "${REPO_ROOT}/build/${METAINFO_FILE_NAME}" \
    "${appdir}/usr/share/metainfo/${METAINFO_FILE_NAME}"
  install -Dm644 "${REPO_ROOT}/build/x-mermaid.xml" \
    "${appdir}/usr/share/mime/packages/x-mermaid.xml"
  install -Dm644 "${REPO_ROOT}/build/icon.svg" \
    "${appdir}/usr/share/icons/hicolor/scalable/apps/dia.svg"
  install -Dm644 "${REPO_ROOT}/vendor-js/${MERMAID_BUNDLE_NAME}" \
    "${appdir}/usr/share/dia/vendor/${MERMAID_BUNDLE_NAME}"

  local size
  for size in 16 32 48 64 128 256 512; do
    install -Dm644 "${REPO_ROOT}/build/icon-${size}x${size}.png" \
      "${appdir}/usr/share/icons/hicolor/${size}x${size}/apps/dia.png"
  done

  mkdir -p "${webkit_dst_dir}"
  cp -a "${webkit_src_dir}/." "${webkit_dst_dir}/"
}

build_appimage() {
  local output_dir="${1}"
  local output_file="${2}"

  local linuxdeploy_bin="${LINUXDEPLOY:-}"
  if [[ -z "${linuxdeploy_bin}" ]]; then
    printf 'LINUXDEPLOY must be set to build the AppImage\n' >&2
    exit 1
  fi

  require_file "${linuxdeploy_bin}"

  local appdir="${output_dir}/AppDir"
  rm -rf "${appdir}"

  local libdir
  libdir="$(pkg-config --variable=libdir webkitgtk-6.0)"
  if [[ "${libdir}" != /usr/* ]]; then
    printf 'unsupported WebKit libdir outside /usr: %s\n' "${libdir}" >&2
    exit 1
  fi

  local libdir_rel="${libdir#/usr/}"
  local webkit_src_dir
  webkit_src_dir="$(webkit_runtime_dir)"
  if [[ ! -d "${webkit_src_dir}" ]]; then
    printf 'missing WebKit runtime directory: %s\n' "${webkit_src_dir}" >&2
    exit 1
  fi

  populate_appdir "${appdir}" "${libdir_rel}" "${webkit_src_dir}"

  local webkit_dst_dir="${appdir}/usr/${libdir_rel}/webkitgtk-6.0"
  local appimages=()

  (
    cd "${output_dir}"
    APPIMAGE_EXTRACT_AND_RUN=1 \
      DEPLOY_GTK_VERSION=4 \
      NO_STRIP=true \
      "${linuxdeploy_bin}" \
      --appdir "${appdir}" \
      --desktop-file "${appdir}/usr/share/applications/${DESKTOP_FILE_NAME}" \
      --icon-file "${appdir}/usr/share/icons/hicolor/512x512/apps/dia.png" \
      --executable "${appdir}/usr/bin/dia" \
      --deploy-deps-only "${webkit_dst_dir}/WebKitNetworkProcess" \
      --deploy-deps-only "${webkit_dst_dir}/WebKitWebProcess" \
      --deploy-deps-only "${webkit_dst_dir}/WebKitGPUProcess" \
      --deploy-deps-only \
        "${webkit_dst_dir}/injected-bundle/libwebkitgtkinjectedbundle.so" \
      --plugin gtk \
      --output appimage
  )

  shopt -s nullglob
  appimages=("${output_dir}"/*.AppImage)
  shopt -u nullglob

  if (( ${#appimages[@]} != 1 )); then
    printf 'expected one AppImage, found %s\n' "${#appimages[@]}" >&2
    exit 1
  fi

  mv "${appimages[0]}" "${output_file}"
}

parse_args() {
  while (( $# > 0 )); do
    case "${1}" in
      --version)
        VERSION="${2}"
        shift 2
        ;;
      --binary)
        BINARY_PATH="${2}"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="${2}"
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

main() {
  parse_args "$@"

  BINARY_PATH="$(resolve_file_path "${BINARY_PATH}")"
  OUTPUT_DIR="$(resolve_dir_path "${OUTPUT_DIR}")"

  require_file "${BINARY_PATH}"
  require_file "${REPO_ROOT}/build/${DESKTOP_FILE_NAME}"
  require_file "${REPO_ROOT}/build/${METAINFO_FILE_NAME}"
  require_file "${REPO_ROOT}/build/x-mermaid.xml"
  require_file "${REPO_ROOT}/build/install.sh"
  require_file "${REPO_ROOT}/build/icon.svg"
  require_file "${REPO_ROOT}/build/AppRun"

  local mermaid_path="${REPO_ROOT}/vendor-js/${MERMAID_BUNDLE_NAME}"
  if [[ ! -f "${mermaid_path}" ]]; then
    printf 'downloading mermaid %s...\n' "${MERMAID_VERSION}" >&2
    mkdir -p "${REPO_ROOT}/vendor-js"
    curl -fsSL -o "${mermaid_path}" "${MERMAID_URL}"
  fi

  local staging_name="dia-${VERSION}-linux-amd64"
  local staging_dir="${OUTPUT_DIR}/${staging_name}"
  local tarball_file="${OUTPUT_DIR}/${staging_name}.tar.gz"
  local deb_file="${OUTPUT_DIR}/dia_${VERSION}_amd64.deb"
  local rpm_file="${OUTPUT_DIR}/dia_${VERSION}_x86_64.rpm"
  local archlinux_file="${OUTPUT_DIR}/dia-${VERSION}-1-x86_64.pkg.tar.zst"
  local appimage_file="${OUTPUT_DIR}/${staging_name}.AppImage"

  rm -rf "${staging_dir}" "${OUTPUT_DIR}/AppDir"
  rm -f "${tarball_file}" "${deb_file}" "${rpm_file}" \
    "${archlinux_file}" "${appimage_file}"

  copy_common_payload "${staging_dir}"
  create_tarball "${staging_dir}" "${tarball_file}"
  package_native_packages "${staging_dir}" "${deb_file}" "${rpm_file}" \
    "${archlinux_file}"
  build_appimage "${OUTPUT_DIR}" "${appimage_file}"
}

main "$@"
