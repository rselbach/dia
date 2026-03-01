#!/bin/sh
update-mime-database /usr/share/mime 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
