# HOWTO / Deep dive — getting the EZ100PU working on Apple Silicon

This is the annotated, chronological account of what it actually took — including the
dead ends — so the method is reproducible and debuggable, not just a magic script.
If you only want it working, use `scripts/install.sh`; read this if you want to
understand or adapt it.

Reference environment: **MacBook Air, Apple M3, macOS 15.7.1 (24G231)**, reader =
`CASTLES EZ100PU`, USB `VID 0x0CA6 / PID 0x0010`.

---

## 0. Confirm the hardware is seen at the USB layer

```sh
system_profiler SPUSBDataType | grep -A10 EZ100PU
```

You should see `Product ID: 0x0010`, `Vendor ID: 0x0ca6 (Castles Technology)`.
If the device isn't even here, it's a cable/port/hardware problem — stop; no driver
will help.

## 1. Understand what macOS already has

```sh
system_profiler SPSmartCardsDataType
```

Out of the box you'll see Apple's CCID driver at
`/usr/libexec/SmartCardServices/drivers/ifd-ccid.bundle` under **Reader Drivers**, but
**no reader** under **Readers**. Apple's driver only recognizes a different Castles
model (the "EZCCID", PID `0x00A0`) — not the EZ100PU (`0x0010`). And even if you added
the PID, the EZ100PU doesn't speak standard CCID, so it wouldn't work.

## 2. Where a third-party driver is allowed to live

Disassembling the daemon reveals the two scan paths:

```sh
strings /System/Library/CryptoTokenKit/com.apple.ifdreader.slotd/Contents/MacOS/com.apple.ifdreader \
  | grep -i SmartCardServices/drivers
# file:///usr/libexec/SmartCardServices/drivers/          (SIP, read-only)
# file:///usr/local/libexec/SmartCardServices/drivers/    (writable — third parties)
```

**Key takeaway: no need to disable SIP.** Everything goes in
`/usr/local/libexec/SmartCardServices/drivers/`.

## 3. The driver: ezIFD

[`ezIFD`](https://github.com/drinkcat/ezIFD) is a CCID fork that patches in the
EZ100PU's three protocol quirks (fake CCID descriptor, big-endian `dwLength`,
`0x00`-prefixed ATR). Building it is where the sharp edges are.

### 3a. Autotools regeneration (the undocumented part)

Upstream's README says `autoreconf --install && ./configure && make`. On a current
Homebrew toolchain (autoconf 2.72, automake 1.18) that **fails**, with two misleading
errors:

- `possibly undefined macro: AC_MSG_ERROR` — this is *not* about `AC_MSG_ERROR`; it
  means **`pkg.m4` is missing** from the macro path (so `PKG_CHECK_MODULES` didn't
  expand, and the first macro after it looks "undefined").
- `AX_PTHREAD: command not found` later — **`ax_pthread.m4`** (from
  `autoconf-archive`) is missing.

Fix: copy both macros into the project's `m4/` dir before regenerating:

```sh
cp "$(brew --prefix)/share/aclocal/pkg.m4"        m4/
cp "$(brew --prefix)/share/aclocal/ax_pthread.m4" m4/
aclocal -I m4 -I "$(brew --prefix)/share/aclocal"
glibtoolize --copy --force --automake   # NOT libtoolize — Homebrew prefixes with 'g'
autoheader --force
autoconf  --force
automake  --add-missing --copy --force --foreign   # drops compile/missing/depcomp
```

Skipping the final `automake` gives `cannot find required auxiliary files: compile missing`.

### 3b. configure — link libusb statically, install to the writable path

```sh
./configure \
  CFLAGS="-DRESPONSECODE_DEFINED_IN_WINTYPES_H" \
  PCSC_CFLAGS="-I$(pwd)/MacOSX" \
  PCSC_LIBS="-framework PCSC" \
  LIBUSB_CFLAGS="$(pkg-config --cflags --static libusb-1.0)" \
  LIBUSB_LIBS="$(brew --prefix)/lib/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security" \
  ZLIB_LIBS="-lz" \
  --enable-usbdropdir="/usr/local/libexec/SmartCardServices/drivers" \
  --disable-static --disable-pcsclite --enable-composite-as-multislot \
  --enable-oslog --disable-dependency-tracking
make -j"$(sysctl -n hw.ncpu)"
```

Why these matter:
- **`PCSC_CFLAGS=-I.../MacOSX`** — the repo's `MacOSX/` shim headers redirect to the
  system `PCSC.framework`; without them configure can't find `ifdhandler.h`
  (it depends on `pcsclite.h`, which only the shims provide on macOS).
- **static libusb (`libusb-1.0.a`)** — makes the bundle self-contained. A dynamically
  linked build would refuse to run on any Mac without Homebrew's libusb in place.
  (ezIFD's own `MacOSX/configure` insists on a static libusb for the same reason, and
  even aborts if it finds a `.dylib`.)
- **`--enable-composite-as-multislot`** — required on macOS (no libhal).

## 4. The three reasons a freshly-built bundle still won't load

This is what cost the most time. The build succeeds, you `make install`, and the
reader *still* doesn't appear. Three separate gates, each with a distinct symptom:

### 4a. Invalid Info.plist XML → `(null):(null)`

`create_Info_plist.pl` writes the author's email into `ifdManufacturerString`
literally: `<nicolas@boichat.ch>`. Those raw angle brackets make the plist invalid
XML. `plutil -lint` fails, and `system_profiler` shows the driver as `(null):(null)`.

```sh
sed -i '' 's/<nicolas@boichat\.ch>/\&lt;nicolas@boichat.ch\&gt;/g' Contents/Info.plist
plutil -lint Contents/Info.plist   # must say OK
```

### 4b. CFBundleIdentifier collision → driver ignored

Upstream keeps `CFBundleIdentifier = fr.apdu.ccid.smartcardccid`, identical to Apple's
system CCID driver. The daemon de-dupes by identifier and keeps only the system one.
Give ours a unique id:

```sh
plutil -replace CFBundleIdentifier -string "fr.apdu.ccid.ezIFD" Contents/Info.plist
```

### 4c. Unsigned/quarantined → "not enabled or allowed"

The bundle must be ad-hoc signed (binds the Info.plist, seals resources). A bundle
you downloaded also carries `com.apple.quarantine`, which the daemon refuses.

```sh
xattr -cr  ifd-ez.bundle
codesign --force --deep --sign - ifd-ez.bundle
codesign --verify --verbose=1 ifd-ez.bundle   # "satisfies its Designated Requirement"
```

## 5. The conflicting vendor driver (`ezusb.bundle`)

Even with a perfect bundle, if the vendor's `ezusb.bundle` is present the reader can
**disappear from PCSC entirely**. It's x86_64-only, matches the same VID/PID, wins the
match, fails to load on arm64, and emits:

```
backgroundtaskmanagementd … effectiveItemDisposition: failed to construct identifier … ezusb.bundle
com.apple.ifdreader … getEffectiveDisposition: error: Error Domain=BTMErrorDomain Code=-98 "invalid parameter"
com.apple.ifdreader … Failed to getEffectiveDisposition
```

Remove it:

```sh
sudo rm -rf /usr/local/libexec/SmartCardServices/drivers/ezusb.bundle
```

**It can come back.** It's installed by the pkg `com.mygreatcompany.pkg.EZ100driver`,
which some HiCOS installers/updates run. Check with
`pkgutil --pkg-info com.mygreatcompany.pkg.EZ100driver`. If your working reader dies
right after a HiCOS update, this is why — re-run `install.sh`.

## 6. Trigger enumeration

`com.apple.ifdreader` is an on-demand launchd job that evaluates readers on USB match
events, then exits. After changing drivers:

```sh
sudo killall com.apple.ifdreader 2>/dev/null || true
# then PHYSICALLY unplug the reader, wait ~3s, plug it back in
system_profiler SPSmartCardsDataType   # reader should now appear under Readers:
```

The physical replug is what actually fires the IOKit match event. A daemon restart
alone is often not enough.

## 7. Prove it works

Three levels of proof, weakest to strongest:

```sh
# (a) macOS sees it
system_profiler SPSmartCardsDataType | sed -n '/Readers:/,/Reader Drivers:/p'

# (b) it enumerates through the PCSC API apps actually use
./scripts/verify.sh

# (c) full stack, incl. a Taiwan e-gov service
#     restart the HiPKI server so it re-scans, then open the self-test page:
launchctl kickstart -k gui/$(id -u)/com.node.HIPKILocalServer.cht
open http://localhost:61161/selfTest.htm
#     step 5 shows the reader + card no.; steps 6–9 (PIN, 簽章驗證, 憑證資訊) pass.
```

## 8. Live debugging

Watch the daemon evaluate the reader as you replug it:

```sh
log stream --predicate 'processImagePath CONTAINS "ifdreader" OR composedMessage CONTAINS "0CA6" OR composedMessage CONTAINS "ezIFD"' --style compact
```

For the HiPKI layer specifically, its log is at
`~/Library/HiPKILocalSignServer/debug.log.<date>`; `"slots": []` there means the
CHT PKCS#11 module (which links the system `PCSC.framework`) got no reader from PCSC —
i.e. the problem is below HiPKI, at the driver/daemon level covered above.

> The HiPKI debug log records your card serial, certificate, and even the PIN you
> type into the test page. Don't commit it or paste it into issues.

---

## Appendix — known-good final state

```
bundle:  /usr/local/libexec/SmartCardServices/drivers/ifd-ez.bundle   (~330 KB)
arch:    Mach-O arm64 (libusb statically linked; deps are all system frameworks)
id:      fr.apdu.ccid.ezIFD
sign:    adhoc, sealed resources, valid Info.plist
plist:   ifdVendorID 0x0CA6 / ifdProductID 0x0010 / name "CASTLES EZUSB Smart Card Reader"
```
