#!/usr/bin/env bash
# install.sh -- install dia into the system or user prefix.
#
# Usage:
#   sudo ./install.sh            # installs to /usr/local
#   ./install.sh ~/.local         # installs to ~/.local (no root needed)

set -euo pipefail

PREFIX="${1:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -Dm755 "${SCRIPT_DIR}/dia"        "${PREFIX}/bin/dia"
install -Dm644 "${SCRIPT_DIR}/dia.desktop" \
  "${PREFIX}/share/applications/dia.desktop"
install -Dm644 "${SCRIPT_DIR}/com.github.rselbach.dia.metainfo.xml" \
  "${PREFIX}/share/metainfo/com.github.rselbach.dia.metainfo.xml"
install -Dm644 "${SCRIPT_DIR}/x-mermaid.xml" \
  "${PREFIX}/share/mime/packages/x-mermaid.xml"
install -Dm644 "${SCRIPT_DIR}/icons/dia.svg" \
  "${PREFIX}/share/icons/hicolor/scalable/apps/dia.svg"

for png in "${SCRIPT_DIR}"/icons/dia-*x*.png; do
  [[ -f "${png}" ]] || continue
  size=$(basename "${png}" | grep -oP '\d+x\d+')
  install -Dm644 "${png}" \
    "${PREFIX}/share/icons/hicolor/${size}/apps/dia.png"
done

if command -v update-mime-database &>/dev/null; then
  update-mime-database "${PREFIX}/share/mime" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f -t "${PREFIX}/share/icons/hicolor" 2>/dev/null || true
fi

echo "dia installed to ${PREFIX}"
