#!/usr/bin/env bash
# install.sh -- install dia into the system or user prefix.
#
# Usage:
#   sudo ./install.sh            # installs to /usr/local
#   ./install.sh ~/.local         # installs to ~/.local (no root needed)

set -euo pipefail

readonly DESKTOP_FILE_NAME="com.rselbach.dia.desktop"
readonly METAINFO_FILE_NAME="com.rselbach.dia.metainfo.xml"

warn_if_cache_update_fails() {
  local cmd_name="${1}"
  shift

  if ! command -v "${cmd_name}" >/dev/null 2>&1; then
    printf 'warning: %s not found; skipping desktop cache refresh\n' "${cmd_name}" >&2
    return
  fi

  if ! "${cmd_name}" "$@"; then
    printf 'warning: %s failed for %s\n' "${cmd_name}" "$*" >&2
  fi
}

main() {
  local prefix="${1:-/usr/local}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  install -Dm755 "${script_dir}/dia" "${prefix}/bin/dia"
  install -Dm644 "${script_dir}/${DESKTOP_FILE_NAME}" \
    "${prefix}/share/applications/${DESKTOP_FILE_NAME}"
  install -Dm644 "${script_dir}/${METAINFO_FILE_NAME}" \
    "${prefix}/share/metainfo/${METAINFO_FILE_NAME}"
  install -Dm644 "${script_dir}/x-mermaid.xml" \
    "${prefix}/share/mime/packages/x-mermaid.xml"
  install -Dm644 "${script_dir}/vendor/mermaid.min.js" \
    "${prefix}/share/dia/vendor/mermaid.min.js"
  install -Dm644 "${script_dir}/icons/dia.svg" \
    "${prefix}/share/icons/hicolor/scalable/apps/dia.svg"

  local png
  for png in "${script_dir}"/icons/dia-*x*.png; do
    [[ -f "${png}" ]] || continue

    local size
    size="${png##*/dia-}"
    size="${size%.png}"
    install -Dm644 "${png}" \
      "${prefix}/share/icons/hicolor/${size}/apps/dia.png"
  done

  warn_if_cache_update_fails update-mime-database "${prefix}/share/mime"
  warn_if_cache_update_fails gtk-update-icon-cache \
    -f \
    -t \
    "${prefix}/share/icons/hicolor"
  warn_if_cache_update_fails update-desktop-database \
    "${prefix}/share/applications"

  echo "dia installed to ${prefix}"
}

main "$@"
