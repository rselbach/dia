#!/bin/sh
# postinstall.sh -- refresh desktop integration caches after package install.

set -eu

if command -v update-mime-database >/dev/null 2>&1; then
  if ! update-mime-database /usr/share/mime; then
    printf '%s\n' "warning: update-mime-database failed" >&2
  fi
else
  printf '%s\n' "warning: update-mime-database not found" >&2
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  if ! gtk-update-icon-cache -f -t /usr/share/icons/hicolor; then
    printf '%s\n' "warning: gtk-update-icon-cache failed" >&2
  fi
else
  printf '%s\n' "warning: gtk-update-icon-cache not found" >&2
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  if ! update-desktop-database /usr/share/applications; then
    printf '%s\n' "warning: update-desktop-database failed" >&2
  fi
else
  printf '%s\n' "warning: update-desktop-database not found" >&2
fi
