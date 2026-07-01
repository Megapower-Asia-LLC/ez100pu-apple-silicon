#!/bin/bash
#
# verify.sh — Prove the reader works end-to-end through the macOS PCSC stack.
#
# Usage:  ./verify.sh          (no sudo needed)
#
# Exits 0 if a reader is present and enumerable, 1 otherwise.
#
set -uo pipefail

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else G=''; R=''; Y=''; N=''; fi

echo "==> 1. Driver bundle installed?"
BUNDLE="/usr/local/libexec/SmartCardServices/drivers/ifd-ez.bundle"
if [[ -d "$BUNDLE" ]]; then
  echo "${G} ✓${N} $BUNDLE"
else
  echo "${R} ✗${N} Not installed — run: sudo ./scripts/install.sh"; exit 1
fi

echo "==> 2. Conflicting vendor driver absent?"
if [[ -e "/usr/local/libexec/SmartCardServices/drivers/ezusb.bundle" ]]; then
  echo "${Y} !${N} ezusb.bundle present — it shadows our driver. Re-run install.sh."
else
  echo "${G} ✓${N} No ezusb.bundle"
fi

echo "==> 3. Reader visible to macOS?"
READERS_BLOCK=$(system_profiler SPSmartCardsDataType 2>/dev/null | sed -n '/Readers:/,/Reader Drivers:/p')
if echo "$READERS_BLOCK" | grep -q '#0'; then
  READER=$(echo "$READERS_BLOCK" | grep '#0' | head -1 | sed 's/^ *//')
  echo "${G} ✓${N} ${READER}"
  READER_VISIBLE=1
else
  echo "${R} ✗${N} No reader listed. Unplug/replug the EZ100PU and try again."; exit 1
fi

echo "==> 4. Enumerable through PCSC API?"
python3 - <<'PY'
import ctypes, ctypes.util, sys
pcsc = ctypes.CDLL(ctypes.util.find_library("PCSC"))
ctx = ctypes.c_void_p()
if pcsc.SCardEstablishContext(0, None, None, ctypes.byref(ctx)) != 0:
    print("   \033[31m ✗\033[0m SCardEstablishContext failed"); sys.exit(1)
blen = ctypes.c_ulong(0)
pcsc.SCardListReaders(ctx, None, None, ctypes.byref(blen))
if blen.value <= 1:
    print("   \033[31m ✗\033[0m No readers via SCardListReaders"); sys.exit(1)
buf = ctypes.create_string_buffer(blen.value)
pcsc.SCardListReaders(ctx, None, buf, ctypes.byref(blen))
readers = [r.decode() for r in buf.raw.split(b"\x00") if r]
print(f"   \033[32m ✓\033[0m SCardListReaders -> {readers}")
pcsc.SCardReleaseContext(ctx)
PY
rc=$?

echo ""
if [[ $rc -eq 0 ]]; then
  echo "${G}All checks passed — the EZ100PU is working.${N}"
else
  echo "${R}PCSC enumeration failed.${N}"
  if [[ "${READER_VISIBLE:-0}" -eq 1 ]]; then
    echo "The reader IS visible to macOS (step 3 passed) but PCSC still returns nothing."
    echo "This usually means the smart-card daemon was already running before the driver"
    echo "was installed, and macOS (SIP) won't let it be force-restarted in place."
    echo "Fix: ${Y}reboot${N}, then re-run this script."
  else
    echo "See README troubleshooting."
  fi
  exit 1
fi
