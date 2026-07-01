#!/bin/bash
#
# install.sh — Make a Castles EZ100PU smart-card reader work on Apple Silicon macOS.
#
# This is the LIGHTWEIGHT path: it installs a small (~330 KB), self-contained,
# ad-hoc-signed arm64 IFD driver bundle (a build of the open-source `ezIFD`
# project) into the macOS-sanctioned third-party driver directory, removes the
# broken vendor driver if present, and re-triggers reader enumeration.
#
# No Homebrew, no Xcode, no build tools required. Just run it.
#
# Usage:
#   sudo ./install.sh
#
# What it does (all idempotent):
#   1. Copies prebuilt/ifd-ez.bundle -> /usr/local/libexec/SmartCardServices/drivers/
#   2. Strips the quarantine xattr and re-applies an ad-hoc code signature
#   3. Removes the vendor's x86_64-only ezusb.bundle if present (it shadows ours)
#   4. Kicks com.apple.ifdreader so macOS re-scans connected readers
#
set -euo pipefail

readonly DRIVERS_DIR="/usr/local/libexec/SmartCardServices/drivers"
readonly BUNDLE_NAME="ifd-ez.bundle"
readonly VENDOR_BUNDLE="ezusb.bundle"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_BUNDLE="${SCRIPT_DIR}/../prebuilt/${BUNDLE_NAME}"

# --- colors ---
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi
info()  { echo "${B}==>${N} $*"; }
ok()    { echo "${G} ✓${N} $*"; }
warn()  { echo "${Y} !${N} $*"; }
die()   { echo "${R} ✗${N} $*" >&2; exit 1; }

# --- preflight ---
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."
if [[ "$(uname -m)" != "arm64" ]]; then
  warn "This Mac is not Apple Silicon (uname -m = $(uname -m))."
  warn "The prebuilt bundle is arm64-only. On Intel, use scripts/build-from-source.sh instead."
fi
[[ $EUID -eq 0 ]] || die "Please run with sudo:  sudo $0"
[[ -d "$SRC_BUNDLE" ]] || die "Prebuilt bundle not found at: $SRC_BUNDLE"

# --- 1. install the bundle ---
info "Installing ${BUNDLE_NAME} -> ${DRIVERS_DIR}"
mkdir -p "$DRIVERS_DIR"
rm -rf "${DRIVERS_DIR:?}/${BUNDLE_NAME}"
cp -R "$SRC_BUNDLE" "${DRIVERS_DIR}/${BUNDLE_NAME}"
ok "Copied bundle"

# --- 2. clear quarantine + re-sign (ad-hoc) ---
# A bundle downloaded from GitHub carries com.apple.quarantine, which makes the
# smart-card daemon refuse to load it. Strip it, then re-seal with an ad-hoc
# signature so the Info.plist is bound and resources are sealed.
xattr -cr "${DRIVERS_DIR}/${BUNDLE_NAME}" 2>/dev/null || true
codesign --force --deep --sign - "${DRIVERS_DIR}/${BUNDLE_NAME}" >/dev/null 2>&1
if codesign --verify --verbose=1 "${DRIVERS_DIR}/${BUNDLE_NAME}" 2>/dev/null; then
  ok "Ad-hoc signature applied and verified"
else
  die "Code signature verification failed"
fi

# --- 3. remove the vendor's broken x86_64 driver if present ---
# The official Castles pkg (com.mygreatcompany.pkg.EZ100driver, bundled with
# some HiCOS installers) drops an x86_64-only ezusb.bundle that matches the same
# USB VID/PID (0x0CA6/0x0010). On Apple Silicon it cannot load, and it SHADOWS
# our working driver — the reader then disappears from PCSC entirely.
if [[ -e "${DRIVERS_DIR}/${VENDOR_BUNDLE}" ]]; then
  warn "Found vendor ${VENDOR_BUNDLE} (x86_64-only) — removing; it shadows our driver."
  rm -rf "${DRIVERS_DIR:?}/${VENDOR_BUNDLE}"
  ok "Removed ${VENDOR_BUNDLE}"
  echo "    Note: a future HiCOS update may re-install it. If the reader stops"
  echo "    working after a HiCOS update, just re-run this script."
else
  ok "No conflicting vendor driver present"
fi

# --- 4. re-trigger reader enumeration ---
info "Restarting the smart-card reader daemon"
killall com.apple.ifdreader 2>/dev/null || true
sleep 2
ok "Daemon signalled (launchd will relaunch it on demand)"

echo ""
ok "${G}Driver installed.${N}"
echo ""
echo "Final step (physical): ${Y}unplug the EZ100PU, wait 3 seconds, plug it back in.${N}"
echo "Then verify with:"
echo "    system_profiler SPSmartCardsDataType"
echo "You should see your reader listed under \"Readers:\"."
echo ""
echo "If you use it with a Taiwan e-gov service (報稅 / 健保 / 自然人憑證):"
echo "    Restart the HiPKI local server so it re-scans, then reload the test page:"
echo "    launchctl kickstart -k gui/\$(id -u)/com.node.HIPKILocalServer.cht  2>/dev/null || true"
