#!/bin/bash
#
# uninstall.sh — Remove the ezIFD driver installed by install.sh.
#
# Usage:  sudo ./uninstall.sh
#
set -euo pipefail

readonly DRIVERS_DIR="/usr/local/libexec/SmartCardServices/drivers"
readonly BUNDLE_NAME="ifd-ez.bundle"

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Please run with sudo:  sudo $0" >&2; exit 1; }

if [[ -e "${DRIVERS_DIR}/${BUNDLE_NAME}" ]]; then
  rm -rf "${DRIVERS_DIR:?}/${BUNDLE_NAME}"
  echo " ✓ Removed ${DRIVERS_DIR}/${BUNDLE_NAME}"
else
  echo " ✓ Nothing to remove (${BUNDLE_NAME} not installed)"
fi

killall com.apple.ifdreader 2>/dev/null || true
echo " ✓ Smart-card daemon restarted"
echo ""
echo "Note: this does NOT reinstall the vendor's ezusb.bundle. If you want the"
echo "original (x86_64) vendor driver back, reinstall HiCOS from the vendor."
