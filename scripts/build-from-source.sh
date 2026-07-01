#!/bin/bash
#
# build-from-source.sh — Build the ezIFD EZ100PU driver from source on Apple Silicon.
#
# This is the TRUST / REPRODUCIBILITY path. Most users should just run
# scripts/install.sh (which uses the prebuilt bundle). Build from source if you
# want to verify what you're installing, or you're on a macOS/arch combo the
# prebuilt bundle doesn't cover.
#
# It reproduces the exact sequence — including the autotools workarounds that
# are NOT in the upstream README but are required on a modern Homebrew toolchain
# (autoconf 2.72 / automake 1.18) — that produced the known-good bundle.
#
# Requirements (installed via Homebrew if missing, with your confirmation):
#   autoconf automake libtool libusb pkg-config flex autoconf-archive
#
# Usage:
#   ./build-from-source.sh            # build into ./build, output ./build/ifd-ez.bundle
#   ./build-from-source.sh --install  # build, then sudo-install via install path
#
set -euo pipefail

readonly REPO_URL="https://github.com/drinkcat/ezIFD.git"
# Pinned so a build reproduces the exact source the prebuilt bundle came from.
# This is also the "corresponding source" reference for the LGPL-2.1 binary.
# See NOTICE.md. Upstream master has been stable at this commit since 2024-04-14.
readonly REPO_COMMIT="555d7eb5a6879df5673ebcdd11c24db586ccba29"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${SCRIPT_DIR}/../build"
readonly BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

if [[ -t 1 ]]; then B=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=''; G=''; Y=''; R=''; N=''; fi
info() { echo "${B}==>${N} $*"; }
ok()   { echo "${G} ✓${N} $*"; }
die()  { echo "${R} ✗${N} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
command -v brew >/dev/null || die "Homebrew required. Install from https://brew.sh"

# --- dependencies ---
info "Checking build dependencies"
DEPS=(autoconf automake libtool libusb pkg-config flex autoconf-archive)
MISSING=()
for d in "${DEPS[@]}"; do
  brew list --formula "$d" >/dev/null 2>&1 || MISSING+=("$d")
done
if (( ${#MISSING[@]} )); then
  echo "${Y}The following Homebrew packages are needed:${N} ${MISSING[*]}"
  read -r -p "Install them now? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cannot build without dependencies."
  brew install "${MISSING[@]}"
fi
ok "Dependencies present"

# --- fetch source ---
info "Fetching ezIFD source (with submodules)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
git clone --recursive "$REPO_URL" "$BUILD_DIR/ezIFD"
cd "$BUILD_DIR/ezIFD"
git checkout --quiet "$REPO_COMMIT"
git submodule update --init --recursive --quiet
ok "Cloned into $BUILD_DIR/ezIFD @ ${REPO_COMMIT:0:12}"

# --- autotools regeneration with the fixes ---
# Upstream's ./bootstrap fails on autoconf 2.72 / automake 1.18 because two m4
# macro files are not on the default search path:
#   * pkg.m4        (from pkg-config)      -> PKG_CHECK_MODULES / PKG_PROG_PKG_CONFIG
#   * ax_pthread.m4 (from autoconf-archive) -> AX_PTHREAD
# Copy both into the project's m4/ dir before regenerating, or configure dies
# with "possibly undefined macro: AC_MSG_ERROR" (a misleading symptom of the
# missing pkg.m4) and later "AX_PTHREAD: command not found".
info "Regenerating build system (with m4 macro fixes)"
for m4file in pkg.m4 ax_pthread.m4; do
  src="${BREW_PREFIX}/share/aclocal/${m4file}"
  [[ -f "$src" ]] || die "Missing $src — is the matching Homebrew formula installed?"
  cp "$src" m4/
done
# glibtoolize (not libtoolize) on macOS — Homebrew prefixes Apple-conflicting tools with 'g'.
aclocal -I m4 -I "${BREW_PREFIX}/share/aclocal"
glibtoolize --copy --force --automake
autoheader --force
autoconf --force
# automake must run to drop the aux files (compile, missing, depcomp) or
# configure aborts with "cannot find required auxiliary files: compile missing".
automake --add-missing --copy --force --foreign
ok "configure generated"

# --- configure with macOS-specific flags ---
# Key choices, mirroring ezIFD's own MacOSX/configure but with an important tweak:
#   * headers come from the bundled MacOSX/ shims (which redirect to the system
#     PCSC.framework) — pass PCSC_CFLAGS=-I$(pwd)/MacOSX
#   * link libusb STATICALLY (the .a) so the resulting bundle has ZERO Homebrew
#     runtime dependency and works on a machine without Homebrew at all
#   * install path = /usr/local/libexec/SmartCardServices/drivers — the writable,
#     non-SIP directory that macOS's ifdreader scans for third-party drivers
#   * --enable-composite-as-multislot — required on macOS (no libhal)
LIBUSB_A="${BREW_PREFIX}/lib/libusb-1.0.a"
[[ -f "$LIBUSB_A" ]] || die "Static libusb not found at $LIBUSB_A"

info "Configuring"
./configure \
  CFLAGS="-DRESPONSECODE_DEFINED_IN_WINTYPES_H" \
  PCSC_CFLAGS="-I$(pwd)/MacOSX" \
  PCSC_LIBS="-framework PCSC" \
  LIBUSB_CFLAGS="$(pkg-config --cflags --static libusb-1.0)" \
  LIBUSB_LIBS="${LIBUSB_A} -framework IOKit -framework CoreFoundation -framework Security" \
  ZLIB_LIBS="-lz" \
  --enable-usbdropdir="/usr/local/libexec/SmartCardServices/drivers" \
  --disable-static \
  --disable-pcsclite \
  --enable-composite-as-multislot \
  --enable-oslog \
  --disable-dependency-tracking

info "Compiling"
make -j"$(sysctl -n hw.ncpu)"
ok "Build complete"

# --- assemble the bundle locally (don't need sudo just to build it) ---
# `make install` writes to /usr/local/... (needs sudo). We instead stage the
# bundle in the build dir so it can be inspected, then hand off to install.sh.
info "Staging bundle"
STAGE="$BUILD_DIR/ifd-ez.bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp src/Info.plist "$STAGE/Contents/Info.plist"
cp src/.libs/libccid.dylib "$STAGE/Contents/MacOS/libccid.dylib"

# FIX 1: upstream's create_Info_plist.pl emits an unescaped <email> in
# ifdManufacturerString, producing INVALID XML. macOS then can't parse the
# plist and the reader shows as "(null):(null)". Escape the angle brackets.
/usr/bin/sed -i '' \
  -e 's/<nicolas@boichat\.ch>/\&lt;nicolas@boichat.ch\&gt;/g' \
  "$STAGE/Contents/Info.plist"

# FIX 2: upstream keeps CFBundleIdentifier = fr.apdu.ccid.smartcardccid, which
# COLLIDES with Apple's system CCID driver. The daemon de-dupes by identifier
# and the third-party driver is ignored. Give it a unique id.
/usr/bin/plutil -replace CFBundleIdentifier -string "fr.apdu.ccid.ezIFD" \
  "$STAGE/Contents/Info.plist"

# Validate the plist actually parses now.
/usr/bin/plutil -lint "$STAGE/Contents/Info.plist" >/dev/null || die "Info.plist is invalid after edits"

# FIX 3: seal the bundle with an ad-hoc signature (binds Info.plist, seals
# resources). Without this the daemon treats it as "not enabled or allowed".
codesign --force --deep --sign - "$STAGE" >/dev/null 2>&1
codesign --verify --verbose=1 "$STAGE" 2>/dev/null || die "Signature verification failed"
xattr -cr "$STAGE" 2>/dev/null || true

ok "Bundle staged at: $STAGE"
echo "    arch:      $(file -b "$STAGE/Contents/MacOS/libccid.dylib")"
echo "    id:        $(codesign -dv "$STAGE" 2>&1 | awk -F= '/Identifier/{print $2}')"
echo "    size:      $(du -sh "$STAGE" | cut -f1)"

# Refresh the repo's prebuilt copy so install.sh picks up this fresh build.
cp -R "$STAGE" "${SCRIPT_DIR}/../prebuilt/ifd-ez.bundle.fresh"
info "A copy was placed at prebuilt/ifd-ez.bundle.fresh for inspection."
echo "    To make it the shipped artifact:  mv prebuilt/ifd-ez.bundle.fresh prebuilt/ifd-ez.bundle"

if [[ "${1:-}" == "--install" ]]; then
  info "Installing (requires sudo)"
  # Point install.sh at the freshly built bundle.
  sudo cp -R "$STAGE" "/usr/local/libexec/SmartCardServices/drivers/ifd-ez.bundle"
  sudo codesign --force --deep --sign - "/usr/local/libexec/SmartCardServices/drivers/ifd-ez.bundle" >/dev/null 2>&1
  [[ -e "/usr/local/libexec/SmartCardServices/drivers/ezusb.bundle" ]] && \
    sudo rm -rf "/usr/local/libexec/SmartCardServices/drivers/ezusb.bundle"
  sudo killall com.apple.ifdreader 2>/dev/null || true
  ok "Installed. Now unplug/replug the reader and run scripts/verify.sh"
else
  echo ""
  echo "Next: install it with"
  echo "    sudo cp -R \"$STAGE\" /usr/local/libexec/SmartCardServices/drivers/"
  echo "  or re-run:  ./build-from-source.sh --install"
fi
