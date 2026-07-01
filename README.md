**繁體中文** | [English](README.en.md)

# EZ100PU 讀卡機在 Apple Silicon macOS 上

讓 **Castles EZ100PU** 晶片讀卡機在 Apple Silicon Mac（M1／M2／M3／M4）上正常運作 —— 包含透過 HiPKI 本機服務讀卡的台灣政府服務（報稅／健保／自然人憑證）。

> **懶人包** —— 原廠從來沒出過 arm64 驅動程式。這個 repo 提供一個小巧（約 330 KB）、自帶所有相依套件、開源的驅動程式，加上一行指令就能安裝。
>
> ```sh
> git clone https://github.com/andrew54068/ez100pu-apple-silicon.git
> cd ez100pu-apple-silicon
> sudo ./scripts/install.sh
> # 照畫面最後顯示的指示做（通常是：把讀卡機拔掉再重插 ——
> # 少數情況需要重新開機，如果讀卡機系統服務原本就在跑的話）
> ./scripts/verify.sh
> ```

---

## 適用對象

你手上有一台 EZ100PU（台灣超常見、用來讀自然人憑證和健保卡的黑灰色 USB 讀卡機），電腦是 Apple Silicon 的 Mac，而且遇到：

- macOS 根本抓不到讀卡機，**或是**
- HiPKI 自我檢測頁面（`http://localhost:61161/selfTest.htm`）第 5 項「選擇讀卡機及卡片」顯示 **X**，讀卡機下拉選單是空的。

支援 macOS 11 以上（在 macOS 15.7.1、Apple M3 上建置並驗證通過）。

---

## 為什麼開箱不能直接用

有三個各自獨立的原因擋在中間。安裝腳本會一次處理掉這三個，以下說明實際狀況。

1. **沒有原生驅動程式。** EZ100PU *不是*標準的 CCID 讀卡機，它有一些協定上的怪癖（長度欄位用大端序、沒有 CCID class descriptor、ATR 前面多一個 `0x00`）。Apple 內建的 CCID 驅動程式會直接忽略它。而原廠唯一的 macOS 驅動程式（`ezusb.bundle`）**只有 x86_64 版本**，在 Apple Silicon 上根本載入不了。

2. **開源驅動程式要修三個地方才載入得了。** 我們用 [`ezIFD`](https://github.com/drinkcat/ezIFD)（一個加上 EZ100PU 支援的 CCID 分支）。但直接用現在的工具鏈編出來還是載入不了，因為：
   - 它產生的 `Info.plist` 裡有一個**沒跳脫的 `<email>`** → XML 無效 → macOS 會把驅動程式顯示成 `(null):(null)`；
   - 它的 `CFBundleIdentifier` 跟 Apple 系統的 CCID 驅動程式**撞名** → 系統服務只會留下其中一個，就忽略掉我們的；
   - 沒簽章／被隔離（quarantine）的 bundle 會被拒絕 → 必須做 **ad-hoc 簽章**。

3. **原廠驅動程式會蓋掉我們的 —— 而且會自己跑回來。** x86_64 的 `ezusb.bundle` 跟我們的驅動程式吃到同一組 USB VID/PID（`0x0CA6/0x0010`）。只要它在，它就會搶到配對、在 arm64 上載入失敗、丟出 `BTMErrorDomain Code=-98`，然後讀卡機就會**整個從 PCSC 消失**。有些 HiCOS 安裝程式／更新會把它重新塞回來（pkg id 為 `com.mygreatcompany.pkg.EZ100driver`）。如果你的讀卡機在更新 HiCOS 之後突然壞掉 —— 就是這個原因，重跑一次 `install.sh` 就好。

### macOS 怎麼找第三方讀卡機驅動程式

`com.apple.ifdreader` 會掃描兩個目錄：

| 路徑 | 可寫入？ | 用途 |
|------|----------|------|
| `/usr/libexec/SmartCardServices/drivers/` | 否（受 SIP 保護） | Apple 內建的 CCID 驅動程式 |
| `/usr/local/libexec/SmartCardServices/drivers/` | **是** | 第三方驅動程式 —— 我們裝在這裡 |

所以**不需要關閉 SIP**。我們把一個簽好章的 arm64 bundle 放進可寫入的那個路徑、移除會衝突的原廠 bundle，再用實體重插觸發重新偵測。

---

## 安裝（推薦：使用預先編譯好的版本）

[`prebuilt/ifd-ez.bundle`](prebuilt/) 裡的預編譯 bundle 是 arm64、**靜態連結 libusb**（完全不依賴 Homebrew 或其他執行環境）、而且已做 ad-hoc 簽章。不需要任何編譯工具。

```sh
sudo ./scripts/install.sh
```

安裝程式會告訴你接下來該做什麼，因為這取決於安裝當下讀卡機系統服務（`com.apple.ifdreader`）是不是已經在跑：

- **原本沒在跑**（第一次安裝通常是這樣）—— 只要**把 EZ100PU 拔掉、等 3 秒、再插回去**（這會觸發讓 macOS 重新掃描的 USB 事件）。
- **原本就在跑**（例如你先前已經開過 HiPKI／電子化政府服務頁面，或這是重新安裝）—— macOS 的系統完整性保護（SIP）不允許就地強制重新啟動它，即使是 root 也一樣，這時要改成**重新開機**。系統開機後會啟動全新的服務，才會讀到新的驅動程式。

不管是哪一種，最後都執行：

```sh
./scripts/verify.sh
```

預期輸出：

```
==> 3. Reader visible to macOS?
 ✓ #01: CASTLES EZUSB Smart Card Reader (ATR:{...})
==> 4. Enumerable through PCSC API?
 ✓ SCardListReaders -> ['CASTLES EZUSB Smart Card Reader']
All checks passed — the EZ100PU is working.
```

如果第 3 項通過、但第 4 項沒過，就是上面說的 SIP／服務未更新的情況 —— 重新開機後再跑一次 `verify.sh`。

### 搭配台灣政府服務（HiPKI）使用

HiPKI 本機服務**只在啟動時掃描一次**讀卡機，所以裝完驅動程式後要推它一把：

```sh
launchctl kickstart -k gui/$(id -u)/com.node.HIPKILocalServer.cht
```

重新整理 `http://localhost:61161/selfTest.htm` —— 第 5 項應該就會顯示你的讀卡機和卡號，第 6～9 項（PIN／簽章驗證／憑證資訊）也都會通過。

HiPKI 自我檢測頁面 **安裝前後對照**：

| 安裝前 | 安裝後 |
|---|---|
| ![HiPKI 自我檢測頁面（安裝前）：第 5 項「選擇讀卡機及卡片」顯示 X，讀卡機下拉選單是空的，第 6～9 項空白](docs/images/hipki-selftest-before.png) | ![HiPKI 自我檢測頁面（安裝後）：9 個項目全部顯示 V，讀卡機與卡號都有帶出，並顯示簽章／解密憑證資訊](docs/images/hipki-selftest-after.png) |

---

## 從原始碼自行編譯（信任路徑）

如果你不想直接信任預編譯的二進位檔，或你的 macOS／架構不一樣，可以自己編。這會編出跟已知可用版本一模一樣的 bundle，包含上游 README 沒寫到的 autotools 修法。

```sh
./scripts/build-from-source.sh            # 編譯到 ./build
./scripts/build-from-source.sh --install  # 編譯後直接安裝
```

相依套件（Homebrew）：`autoconf automake libtool libusb pkg-config flex autoconf-archive`。腳本會在缺套件時詢問你是否安裝。每一步做什麼、為什麼要這樣做，完整的逐步說明請看 [`docs/HOWTO.md`](docs/HOWTO.md)。

---

## 移除

```sh
sudo ./scripts/uninstall.sh
```

---

## 檔案結構

```
prebuilt/ifd-ez.bundle      預編譯 arm64 驅動程式（ad-hoc 簽章、靜態連結 libusb）
scripts/install.sh          一行指令安裝（使用預編譯 bundle）
scripts/uninstall.sh        移除驅動程式
scripts/verify.sh           端到端驗證：PCSC 列舉（不需 sudo）
scripts/build-from-source.sh  可重現建置，已套用所有修正
docs/HOWTO.md               詳細技術剖析／疑難排解
```

---

## 疑難排解

| 症狀 | 原因 | 解法 |
|------|------|------|
| `system_profiler SPSmartCardsDataType` 裡驅動程式顯示成 `(null):(null)` | `Info.plist` XML 無效 | 重新安裝 —— 安裝程式提供的是有效、已簽章的 plist |
| 讀卡機本來好好的，更新 HiCOS 之後就壞了 | `ezusb.bundle` 被重新塞回來，蓋掉我們的驅動程式 | 重跑 `sudo ./scripts/install.sh` |
| `system_profiler` 有看到讀卡機，但 HiPKI 下拉選單裡**沒有** | HiPKI 服務的 slot 清單過期了 | 執行 `launchctl kickstart -k gui/$(id -u)/com.node.HIPKILocalServer.cht` 再重新整理頁面 |
| 安裝後 `Readers:` 底下空空如也 | USB 配對事件沒被觸發 | 實體拔插讀卡機一次 |
| `verify.sh` 第 3 項（`system_profiler`）看得到讀卡機，但第 4 項（PCSC／`SCardListReaders`）還是失敗，就算重插也一樣 | 安裝前 `com.apple.ifdreader` 服務本來就在跑 —— 它受 SIP 保護，macOS 不允許任何人（包含 root）就地強制它重新載入驅動程式目錄 | **重新開機**，再跑一次 `./scripts/verify.sh` —— `install.sh` 會偵測到這個情況並事先告訴你 |
| `install.sh` 在 Intel 機器上拒絕執行 | 預編譯版只有 arm64 | 改用 `./scripts/build-from-source.sh` |

進一步診斷 —— 即時觀察系統服務怎麼判定這台讀卡機能不能用：

```sh
log stream --predicate 'processImagePath CONTAINS "ifdreader" OR composedMessage CONTAINS "0CA6"' --style compact
# 然後重插讀卡機
```

---

## 致謝與授權

- 驅動程式：[`ezIFD`](https://github.com/drinkcat/ezIFD)（作者 drinkcat）—— 是 Ludovic Rousseau 的 [CCID](https://github.com/LudovicRousseau/CCID) 的分支。以 **LGPL-2.1** 授權；[`prebuilt/`](prebuilt/) 裡的 bundle 是該原始碼的建置產物（釘選的 commit 與完整授權條款見 [`NOTICE.md`](NOTICE.md) 和 [`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt)），並沿用相同授權。
- 本 repo 的封裝部分（腳本、文件、安裝程式）—— MIT 授權，見 [`LICENSE`](LICENSE)。

來源出處、確切的上游 commit、所做的修改，以及如何重建對應原始碼，都記錄在 [`NOTICE.md`](NOTICE.md)。要驗證預編譯二進位檔的完整性，可執行 `cd prebuilt && shasum -a 256 -c SHA256SUMS`。

## 免責聲明

本軟體**以「現狀」提供，不附任何形式的擔保，使用風險由使用者自行承擔。** 它會把第三方驅動程式安裝到系統的安全性路徑，並用於具有法律效力的數位憑證硬體（例如台灣自然人憑證）。作者對於因使用本軟體而產生的任何損害、資料遺失，或簽章失敗／無效，概不負責。若你需要具法律效力的簽章，請透過官方管道另行驗證。本文件不構成法律意見。詳見 [`NOTICE.md`](NOTICE.md) 第 5 節。

本專案**與** Castles Technology、中華電信（HiCOS／HiPKI）或 Apple **均無任何關聯，亦未經其授權或背書**。文中產品名稱僅用於說明相容性。
