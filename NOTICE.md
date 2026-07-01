# NOTICE — provenance, third-party licenses, and modifications

This file documents where the code in this repository comes from, what was
changed, and the licenses that apply. It exists to comply with the
redistribution terms of the bundled open-source components (notably the
LGPL-2.1 requirement to give notice of the source and of modifications) and to
be transparent about the prebuilt binary.

Nothing in this repository contains proprietary code from Castles Technology,
Chunghwa Telecom (中華電信), HiCOS, or Apple. The only references to those
products are names used descriptively to state hardware/software compatibility
(nominative use).

---

## 1. The prebuilt driver (`prebuilt/ifd-ez.bundle`)

The driver is a compiled build of **ezIFD**, an open-source fork of the **CCID**
driver that adds support for Castles EZUSB / EZ100PU readers.

| Component | Upstream | Pinned commit | License |
|-----------|----------|---------------|---------|
| ezIFD (CCID fork) | https://github.com/drinkcat/ezIFD | `555d7eb5a6879df5673ebcdd11c24db586ccba29` (2024-04-14) | LGPL-2.1 |
| PCSC (submodule, headers only) | https://github.com/LudovicRousseau/PCSC | `549922c1355fdd1e85eb0a952fefda7bb96e286a` | BSD-3-Clause |
| PCSC-contrib (submodule) | https://github.com/LudovicRousseau/PCSC-contrib | `deebf6fca223d799b19de3c359697bed7b694bf0` | — |
| libusb (statically linked) | https://github.com/libusb/libusb | v1.0.29 | LGPL-2.1 |

**Corresponding source (LGPL-2.1 §4):** the complete source for the driver is
the ezIFD repository at the pinned commit above, plus libusb v1.0.29. Both are
publicly available at the URLs listed. `scripts/build-from-source.sh` rebuilds
the exact bundle from that source on any Apple Silicon Mac.

**Relinking (LGPL-2.1 §6, static libusb):** because libusb is statically linked
into the driver, and both the driver and libusb are LGPL-2.1, you may obtain the
above sources and rebuild/relink a modified version using
`scripts/build-from-source.sh`.

**Integrity:** SHA-256 checksums of the shipped bundle are in
`prebuilt/SHA256SUMS`. Verify with:

```sh
cd prebuilt && shasum -a 256 -c SHA256SUMS
```

## 2. Modifications made in this repository

The upstream ezIFD source is **not** modified. The changes are applied to the
*generated* driver bundle at build/package time, and are the minimum needed to
make the driver load on modern Apple Silicon macOS:

1. **`Info.plist` XML fix** — upstream's `create_Info_plist.pl` emits an
   unescaped `<email>` in `ifdManufacturerString`, producing invalid XML that
   macOS cannot parse. The angle brackets are escaped to `&lt;`/`&gt;`.
2. **`CFBundleIdentifier` change** — changed from `fr.apdu.ccid.smartcardccid`
   (which collides with Apple's built-in CCID driver) to `fr.apdu.ccid.ezIFD`.
3. **Ad-hoc code signature** — the bundle is signed with an ad-hoc signature so
   the macOS smart-card daemon will load it. No developer identity is embedded.

All three are documented and performed in the open in `scripts/build-from-source.sh`
and `scripts/install.sh`.

## 3. Licenses

- The **driver binary** (`prebuilt/ifd-ez.bundle`) is distributed under the
  **LGPL-2.1** — see `licenses/LGPL-2.1.txt`. This is the license of ezIFD/CCID
  and of libusb.
- The **packaging in this repository** (scripts, documentation, installer) is
  distributed under the **MIT license** — see `LICENSE`.

## 4. Trademarks

"Castles" and "EZ100PU" are trademarks of Castles Technology Co., Ltd.
"HiCOS", "HiPKI", and related marks are trademarks of Chunghwa Telecom Co., Ltd.
"Apple", "macOS", and "Apple Silicon" are trademarks of Apple Inc.
These names are used only to identify the hardware and software this driver is
compatible with. This project is **not affiliated with, authorized by, or
endorsed by** any of those companies.

## 5. Disclaimer of warranty and liability

This software is provided "AS IS", without warranty of any kind, express or
implied. It installs a third-party driver into a system security path and is
used with digital-certificate hardware (e.g. Taiwan 自然人憑證) that can carry
legal weight. **Use it at your own risk.** The authors and contributors are not
liable for any damage, data loss, failed or invalid digital signatures, or any
other loss arising from its use. Verify the integrity of the prebuilt binary
(section 1) or build from source (section 1) if you have any doubt. If a
correct and legally-reliable digital signature matters to you, independently
verify results through official channels.

This document is not legal advice.
