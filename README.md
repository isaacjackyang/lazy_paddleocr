# OCR 套件打包說明

## 目錄

1. [這個版本的變更](#這個版本的變更)
2. [一般使用方式](#一般使用方式)
3. [目前實測可跑 CUDA 的版本組合](#目前實測可跑-cuda-的版本組合)
4. [補充文件](#補充文件)
5. [小型代理啟動腳本](#小型代理啟動腳本)
6. [PowerShell 腳本指南](#powershell-腳本指南)
7. [攜帶式 ZIP 打包流程](#攜帶式-zip-打包流程)
8. [One-folder EXE 打包流程](#one-folder-exe-打包流程)
9. [One-file EXE 打包流程](#one-file-exe-打包流程)
10. [Docker 版安裝與啟動流程](#docker-版安裝與啟動流程)
11. [PP-StructureV3 座標疊圖檢視器](#pp-structurev3-座標疊圖檢視器)
12. [輸出檔命名](#輸出檔命名)
13. [安裝器維護向更新](#安裝器維護向更新)
14. [這個版本的其他修正](#這個版本的其他修正)
15. [新的互動式輸出選項](#新的互動式輸出選項)
===========================================================================================================================================
## 這個版本的變更

- 根目錄 `install_paddle_all.bat` 會以 GPU-only 模式安裝。
- 若相容，會重用既有的 `.venv`。
- 若相容，會重用既有的 PaddlePaddle。
- 若相容，會重用既有的 PaddleOCR / PyMuPDF。
- 直接執行 `tools\install_paddle_ocr_suite.ps1` 時，若未加 `-RequireGpu`，GPU 安裝或檢查失敗仍會自動回退到 CPU。
- `distribution_tools\build_full_portable_bundle.bat` 現在會建立 GPU-only wheelhouse，不再包含 CPU fallback wheel。
- 啟動器預設會遞迴掃描子資料夾。
- 如果你只想掃描目前資料夾，請使用 `-NoRecursive`。

## 一般使用方式

1. 雙擊 `install_paddle_all.bat`
2. 或執行 `tools\install_paddle_ocr_suite.ps1 -Mode gpu -RequireGpu`
3. 安裝完成後查看畫面最後的安裝摘要

如果安裝在完成前中斷，安裝程式現在會顯示手動修復清單，並把相同的 PowerShell 指令寫入 `tools\install_manual_recovery.ps1`。
如果你想保留「GPU 失敗時自動回退 CPU」的通用模式，請直接執行 `tools\install_paddle_ocr_suite.ps1`，不要加 `-RequireGpu`。
如果你想一次建立 CPU 與 GPU 兩套獨立環境，可改用 `tools\install_paddleocr.ps1`。

### 在新電腦安裝完整 GPU-only OCR 方案

如果你的目標是：

- Windows
- `paddlepaddle 3.x`
- `PP-OCRv5`
- `PP-StructureV3`
- 全部都必須用 GPU 執行

請直接走 `install_paddle_all.bat` 這條線。它現在等同於：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\install_paddle_ocr_suite.ps1 -Mode gpu -RequireGpu
```

也就是說，只要 GPU 安裝、GPU 驗證、`PP-OCRv5` GPU 初始化、或 `PP-StructureV3` GPU 初始化有任何一步失敗，安裝程式就會直接停止，不會偷偷回退成 CPU 環境。

**安裝前先確認**

1. 新電腦是 Windows。
2. 有 NVIDIA GPU，且顯示卡驅動已安裝完成。
3. 最好先確認 `nvidia-smi` 可以正常執行。
4. 專案請放在短且可寫入的路徑，例如 `D:\PaddleOCR`。
5. 如果這台電腦沒有 Python，安裝器會嘗試自動安裝支援版本的 Python。

**方法 A：直接從 repo / 解壓後資料夾安裝**

1. 把整個專案資料夾放到新電腦，例如 `D:\PaddleOCR`。
2. 如果裡面已經有舊的 `.venv`，先刪除。
3. 雙擊 `install_paddle_all.bat`。
4. 等安裝器完成。
5. 最後檢查摘要至少要看到：
   - `GPU required    : YES`
   - `Paddle mode     : gpu`
   - `PP-OCRv5        : READY`
   - `PP-StructureV3  : READY`

**方法 B：帶 GPU-only 攜帶包去新電腦安裝**

1. 在來源電腦先建立完整 GPU-only 攜帶包：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeModelCache -IncludeWheelhouse -GpuOnlyWheelhouse
```

2. 把產出的 ZIP 複製到新電腦。
3. 解壓到短路徑，例如 `D:\PaddleOCR`。
4. 保持整個資料夾結構完整，不要只拿其中一部分檔案。
5. 雙擊 `install_paddle_all.bat`。

這條路線的好處是：

- 模型快取可以一起帶過去
- wheelhouse 也能一起帶過去
- 新電腦比較不依賴即時網路下載

但要注意：

- `-GpuOnlyWheelhouse` 不會附 CPU fallback wheel
- 所以目標電腦必須真的能跑 GPU
- 如果 GPU 驗證失敗，安裝會直接失敗，不會改裝 CPU 版

**如果新電腦 GPU 安裝失敗，優先檢查**

1. `nvidia-smi` 是否正常。
2. 顯示卡驅動是否太舊。
3. 目前使用的 CUDA wheel 標籤是否合適。

如果你需要手動指定 GPU wheel 來源，可改用：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\install_paddle_ocr_suite.ps1 -Mode gpu -RequireGpu -Cuda cu118
```

可選標籤目前是：

- `cu118`
- `cu126`
- `cu129`
- `cu130`

如果你不確定，就先從預設值開始；只有在 GPU wheel 安裝或初始化失敗時，再換別的 `-Cuda` 標籤重試。
### 目前實測可跑 CUDA 的版本組合

目前這個 repo 在現有 `.venv` 內，已於 2026-06-09 實際驗證可用的 GPU 組合如下：

- `paddlepaddle-gpu 3.3.1`
- `paddleocr 3.6.0`
- `paddlex 3.6.1`
- `nvidia-cudnn-cu12 9.9.0.52`
- `PP-OCRv5`：GPU 初始化成功
- `PP-StructureV3`：GPU 初始化成功
- Paddle runtime device：`gpu:0`
- CUDA runtime：`cu12`

如果用一行表示，就是：

```text
paddleocr 3.6.0 + paddlex 3.6.1 + PP-OCRv5 + PP-StructureV3 + paddlepaddle-gpu 3.3.1 + CUDA cu12 + cuDNN 9.9.0.52
```

這裡不是只看套件版本號，而是有做實際 GPU 初始化驗證：

- `PaddleOCR(device="gpu", ...)` = `OK`
- `PPStructureV3(device="gpu")` = `OK`

另外，這次清理過 `.venv` 內的舊版 NVIDIA wheel / DLL 殘留：

- 已移除 `nvidia-*-cu11` 套件
- 已移除 cuDNN 8 殘留 DLL
- 目前只保留 cu12 / cuDNN 9 相關 runtime

所以如果你要在新電腦重建一模一樣的 GPU-only 環境，最穩的目標就是先對齊這組版本，再檢查安裝摘要是否同樣顯示：

- `GPU required    : YES`
- `Paddle mode     : gpu`
- `PP-OCRv5        : READY`
- `PP-StructureV3  : READY`
===========================================================================================================================================
## 補充文件

補充說明與歷次整理紀錄已集中在 `docs\`：

- `docs\問題與處理紀錄.md`
- `docs\不同版本適合用途對照.txt`
===========================================================================================================================================
## 小型代理啟動腳本

如果你不想把整包 `.venv` 複製到每個文件資料夾，可以改用小型代理啟動腳本：

1. 先在主安裝資料夾執行一次 `register_shared_ocr_home.cmd`
   或 `powershell.exe -ExecutionPolicy Bypass -File .\tools\register_shared_ocr_home.ps1`
2. 把 `ocr_here.bat` 複製到你要做 OCR 的資料夾旁
3. 之後直接雙擊那個小 `.bat` 即可，它會自動回到主安裝資料夾裡的 `.venv` 啟動 OCR

差異：

- `ocr_here.bat`：以該 `.bat` 所在資料夾為掃描根目錄，預設遞迴掃描子資料夾
- `ocr_here.bat -NoRecursive`：只掃描該 `.bat` 所在的目前資料夾

補充：

- `tools\install_paddle_ocr_suite.ps1` 與 `tools\start_ocr_launcher.ps1` 現在也會自動更新共享 OCR 路徑登記
- 如果主安裝資料夾搬家了，只要在新位置再執行一次 `register_shared_ocr_home.cmd`
- 跨機器發佈、可攜打包、EXE 打包與 Docker 隔離腳本已整理到 `distribution_tools\`

===========================================================================================================================================

## PowerShell 腳本指南

### `tools\install_paddleocr.ps1`

> 這是精簡版雙環境安裝腳本，會分別建立 CPU 與 GPU 兩套獨立 venv。

**功能**

- 建立 `.venv-cpu` 與 `.venv-gpu`
- 安裝 CPU 版 `paddlepaddle` 與 GPU 版 `paddlepaddle-gpu`
- 兩套環境都安裝 `paddlex[ocr]`
- 分別測試 `OCR` 與 `PP-StructureV3` pipeline

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\install_paddleocr.ps1
```

**適合使用時機**

- 你想同時保留 CPU 與 GPU 兩套環境
- 你想明確分開測試 CPU / GPU pipeline

===========================================================================================================================================

### `tools\install_paddle_ocr_suite.ps1`

> 這是主要的安裝腳本，用來建立、修復或重建本機 OCR 環境。

**功能**

- 建立或重用 `.venv`
- 安裝 PaddlePaddle、PaddleOCR、PyMuPDF 與 PP-StructureV3 相依套件
- 會同時驗證 `PP-OCRv5` 與 `PP-StructureV3` 都能成功初始化，任一失敗都視為安裝失敗
- 預設使用 GPU 模式；加上 `-RequireGpu` 時會強制 GPU-only，若 GPU 安裝或驗證失敗就直接停止
- 安裝完成後會顯示已安裝元件與版本摘要

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\install_paddle_ocr_suite.ps1
```

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\install_paddle_ocr_suite.ps1 -Mode gpu -RequireGpu
```

**常用參數**

- `-Mode gpu` 或 `-Mode cpu`：選擇偏好的安裝模式
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`：指定 Paddle GPU 套件來源版本
- `-StrictVenvPythonMatch`：如果 `.venv` 的 Python major.minor 與偵測到的系統 Python 不一致，就重建 `.venv`
- `-RequireGpu`：要求最終環境一定要通過 GPU 驗證，不允許自動回退到 CPU
**適合使用時機**

- 這台電腦尚未完成環境安裝
- `.venv` 損壞或遺失
- 你想切換成 CPU 優先或 GPU 優先的安裝行為

===========================================================================================================================================

### `tools\start_ocr_launcher.ps1`

> 這是 OCR 啟動腳本，適合在環境已經準備好的情況下直接執行，不會進行套件安裝。

**功能**

- 檢查 `.venv\Scripts\python.exe` 與 `tools\run_ocr_launcher.py` 是否存在
- 依指定掃描設定啟動 OCR 啟動器
- 預設使用遞迴掃描
- 啟動後會依序詢問掃描類型、模式、裝置、PDF DPI、OCR 參數、V3 專屬參數與輸出格式

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\start_ocr_launcher.ps1
```

**常用參數**

- `-Root <folder>`：指定要掃描的資料夾，而不是使用專案資料夾
- `-NoRecursive`：只掃描目前資料夾，不遞迴
- `-Device Auto|CPU|GPU`：設定互動選單中的預設執行裝置；仍可在啟動後重新選擇
- `-PdfDpi 200`：設定互動選單中的預設 PDF DPI
- `-KeepPdfImages`：保留 PDF 轉出的頁面圖片
- `-ImageExts` / `-PdfExts`：覆寫副檔名過濾條件

**適合使用時機**

- 安裝已經完成
- 你只想再次執行 OCR，不想重跑安裝流程

===========================================================================================================================================

### `tools\register_shared_ocr_home.ps1`

> 這是共享 OCR 主目錄登記腳本，供 `ocr_here.bat` 這類代理啟動器使用。

**功能**

- 將目前專案根目錄登記為共享 OCR home
- 同步更新：
  - 使用者環境變數 `PADDLE_OCR_HOME`
  - `HKCU\Software\PaddleOCRLauncher\InstallRoot`
  - `%LOCALAPPDATA%\PaddleOCRLauncher\shared_install_root.txt`

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\register_shared_ocr_home.ps1
```

也可以直接雙擊根目錄的 `register_shared_ocr_home.cmd`。

**適合使用時機**

- 你要開始使用 `ocr_here.bat`
- 主安裝資料夾搬家後，需要重新登記共享 OCR home

===========================================================================================================================================

### `tools\merge_txt_by_serial.ps1`

> 這是依檔名流水號排序後合併 TXT 的輔助工具。

**功能**

- 掃描指定資料夾中的 `.txt`
- 依檔名開頭或結尾的流水號排序
- 盡量用合理編碼讀取，再輸出成單一 UTF-8 BOM 檔案

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\merge_txt_by_serial.ps1
```

**適合使用時機**

- 你已經有一批 OCR TXT 輸出，想依頁碼或流水號合併
- 你需要用較穩定的方式處理混合編碼 TXT

===========================================================================================================================================

### `distribution_tools\install_paddle_ocr_docker.ps1`

> 這是 Docker 版的一鍵安裝腳本，會盡量沿用目前 `install + start` 的操作感。

**功能**

- 如果還沒安裝 Docker Desktop，會嘗試用 `winget` 安裝
- 啟動 Docker Desktop 並等待 Docker engine 就緒
- 建立 Docker 專用的模型快取資料夾
- 建立 Docker OCR 映像檔
- 預設安裝完成後直接啟動 Docker 版 OCR launcher

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\install_paddle_ocr_docker.ps1
```

**常用參數**

- `-NoAutoStart`：安裝完成後不要立刻啟動
- `-ForceRebuild`：強制重建 Docker image
- `-ImageTag`：指定 Docker image 名稱

**適合使用時機**

- 你想避開本機 Python / venv / Paddle 版本污染
- 你想把 OCR 執行環境隔離在 Docker 內

===========================================================================================================================================

### `distribution_tools\start_ocr_launcher_docker.ps1`

> 這是 Docker 版的 OCR 啟動腳本，互動流程和原本 `tools\start_ocr_launcher.ps1` 類似。

**功能**

- 用 Docker container 啟動 `tools\run_ocr_launcher.py`
- 直接掛載目前專案資料夾，讓 OCR 輸出仍寫回主機
- 將 Docker 版模型快取保存在 `.docker_data\paddlex\official_models`

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\start_ocr_launcher_docker.ps1
```

**常用參數**

- `-Root <folder>`：指定要掃描的資料夾
- `-NoRecursive`：只掃描目前資料夾，不遞迴
- `-PdfDpi 200`：調整 PDF 轉圖 DPI

**適合使用時機**

- Docker image 已建立完成
- 你要用 Docker 隔離環境來跑互動式 OCR

===========================================================================================================================================

### `distribution_tools\build_wheelhouse.ps1`

> 這是單獨輸出 wheelhouse 的腳本，預設輸出到根目錄 `wheel\`，不會另外建立 ZIP。

**功能**

- 從目前 `.venv` 匯出安裝所需的 wheel 檔
- 會同時輸出 `python-version.txt`、`requirements-lock.txt`、`wheelhouse-mode.txt`
- 如果目前 `.venv` 是 GPU 版，預設會建立 GPU-only wheelhouse
- 可選擇額外加入 CPU fallback 的 Paddle wheel

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_wheelhouse.ps1
```

或直接雙擊：

- `distribution_tools\build_wheelhouse.bat`

**常用參數**

- `-OutputDir .\wheel`：指定 wheelhouse 輸出資料夾
- `-IncludeCpuFallback`：若目前 `.venv` 是 GPU 版，額外下載 CPU 版 `paddlepaddle` fallback wheel

**適合使用時機**

- 你只想先做好一份本機 wheel 資料夾
- 你要把 wheel 單獨帶去別台電腦，不想先包成 ZIP
- 你想先驗證目前 `.venv` 是否真的能匯出完整 wheel 集合

補充：

- 目前安裝器會優先讀根目錄 `wheel\`，找不到時才會回頭讀 `bundled_wheels\`
- 如果目前 `.venv` 是 GPU 版，這支腳本預設產生的就是 GPU-only wheelhouse

===========================================================================================================================================

### `distribution_tools\build_portable_bundle.ps1`

> 這是建立攜帶式 ZIP 的打包腳本，輸出到 `dist\`。如果你要搬到另一台電腦，這是主要的完整攜帶包腳本。

**可包含內容**

- 安裝腳本與啟動腳本
- 模型快取
- 從目前 `.venv` 匯出的 wheel 檔

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeModelCache -IncludeWheelhouse
```

**常用參數**

- `-IncludeModelCache`：包含 `%USERPROFILE%\.paddlex\official_models`
- `-IncludeWheelhouse`：包含本機 wheel 檔，降低目標電腦對網路下載的依賴
- `-GpuOnlyWheelhouse`：建立只包含 `paddlepaddle-gpu` 的 wheelhouse，不附帶 CPU fallback wheel；需搭配 `-IncludeWheelhouse`
- `-IncludeTests`：包含測試檔案
- `-IncludeScreenshots`：包含 `Screenshots` 資料夾

**適合使用時機**

- 你想產生最完整的攜帶式 ZIP
- 目標電腦可能不容易下載套件或模型

===========================================================================================================================================

### `distribution_tools\build_onefolder_exe.ps1`

> 這是建立 one-folder EXE 的打包腳本，輸出到 `dist_exe\`。

**功能**

- 使用 PyInstaller 建立真正的 Windows `.exe`
- 把目前 `.venv` 中的 Python 執行環境與 OCR 相依套件一起打包
- 可選擇把 PaddleX 模型快取也一起帶入

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefolder_exe.ps1
```

**常用參數**

- `-IncludeModelCache`：把模型快取一起打進 EXE 資料夾
- `-OutputDir`：指定輸出資料夾
- `-BundleName`：指定產出包名稱

**適合使用時機**

- 你要的是可直接執行的 EXE 資料夾，而不是 ZIP 安裝包
- 目標電腦預期直接執行打包好的環境

===========================================================================================================================================

### `distribution_tools\build_onefile_exe.ps1`

> 這是建立 one-file EXE 的打包腳本，輸出到 `dist_exe\`。

**功能**

- 使用 PyInstaller 建立單一 `.exe`
- 可選擇把 PaddleX 模型快取一起嵌入到同一個檔案中
- 執行時會先解開到暫存目錄，再啟動 OCR

**常用執行方式**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefile_exe.ps1
```

**常用參數**

- `-IncludeModelCache`：把模型快取一起嵌入單檔 EXE
- `-OutputDir`：指定輸出資料夾
- `-BundleName`：指定產出檔名開頭

**適合使用時機**

- 你要的是單一 `.exe`，不想另外帶一整個資料夾
- 你可以接受每次啟動前會先解壓到暫存目錄
- 如果加入模型快取，檔案會非常大，啟動也會更慢

===========================================================================================================================================
## 攜帶式 ZIP 打包流程

如果你要把這個專案搬到另一台電腦，請使用攜帶式 ZIP 打包。

### 建立精簡版攜帶式 ZIP

- 雙擊 `distribution_tools\build_portable_bundle.bat`
- 或執行 `distribution_tools\build_portable_bundle.ps1`

它會在 `dist\` 建立乾淨的 ZIP，包含啟動與安裝腳本，但不包含：

- `.venv`
- 安裝紀錄檔
- 產生的 OCR 輸出檔
- `Screenshots`

===========================================================================================================================================

### 為另一台電腦建立較完整的攜帶式 ZIP

如果目標電腦常在 `wheel` / `pip` 安裝時出問題，建議建立完整版：

- 雙擊 `distribution_tools\build_full_portable_bundle.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeModelCache -IncludeWheelhouse -GpuOnlyWheelhouse
```

這個版本會額外包含：

- `bundled_model_cache\official_models`
- `bundled_wheels`

安裝程式會：

- 自動匯入隨包提供的模型快取
- 優先使用本機 wheel，再考慮走網路下載
- 優先選擇與建立 wheelhouse 時相同的 Python major.minor 版本
- 只提供 GPU wheel，不提供 CPU fallback wheel

===========================================================================================================================================

### 建立包含模型快取的攜帶式 ZIP

執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeModelCache
```

如果來源電腦存在 `%USERPROFILE%\.paddlex\official_models`，ZIP 內會將其打包到 `bundled_model_cache\official_models`。
在目標電腦上，`tools\install_paddle_ocr_suite.ps1` 會在安裝檢查前自動匯入缺少的模型快取。

===========================================================================================================================================

### 建立只包含本機 wheel 的攜帶式 ZIP

執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeWheelhouse
```

這需要本機已有可用的 `.venv`，因為 wheelhouse 是從目前環境匯出的。
如果你要建立純 GPU 用的專用 wheelhouse，請改用：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_portable_bundle.ps1 -IncludeWheelhouse -GpuOnlyWheelhouse
```

如果你根本不想先打 ZIP，只想單獨產出本機 `wheel\` 資料夾，請改用：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_wheelhouse.ps1
```

===========================================================================================================================================

## One-folder EXE 打包流程

如果你要的是可直接執行的資料夾與真正的 `exe`，請使用 one-folder builder。

### 建立 one-folder EXE

- 雙擊 `distribution_tools\build_onefolder_exe.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefolder_exe.ps1
```

它會在 `dist_exe\` 建立一個資料夾，內容包含：

- `PaddleOCRLauncher_... .exe`
- 打包後的 Python runtime 檔案
- 目前 `.venv` 中的 Paddle / PaddleOCR / PaddleX 相依套件

===========================================================================================================================================

### 建立包含模型快取的 one-folder EXE

執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefolder_exe.ps1 -IncludeModelCache
```

如果建立機器上存在 `%USERPROFILE%\.paddlex\official_models`，它會一起被打包進 EXE 資料夾。
第一次執行時，啟動器會把缺少的內建模型匯入到：
`%USERPROFILE%\.paddlex\official_models`

===========================================================================================================================================

## One-file EXE 打包流程

如果你要的是單一 `.exe`，請使用 one-file builder。

### 建立 one-file EXE

- 雙擊 `distribution_tools\build_onefile_exe.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefile_exe.ps1
```

它會在 `dist_exe\` 建立一個單獨的 `.exe`。
這個版本不會在輸出資料夾再放一整個 runtime 資料夾，但執行時仍會先解壓到系統暫存目錄。

===========================================================================================================================================

### 建立包含模型快取的 one-file EXE

執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\build_onefile_exe.ps1 -IncludeModelCache
```

如果建立機器上存在 `%USERPROFILE%\.paddlex\official_models`，它會一起被嵌入 EXE。
這樣比較接近離線可用，但檔案大小會顯著增加，而且每次啟動都會更慢。

===========================================================================================================================================

## Docker 版安裝與啟動流程

如果你想避開本機 Python / Paddle 環境衝突，可以改用 Docker 版。

### 一鍵安裝並啟動 Docker 版 OCR

- 雙擊 `distribution_tools\install_and_start_docker.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\install_paddle_ocr_docker.ps1
```

這支腳本會：

- 嘗試安裝 Docker Desktop
- 等 Docker engine 可用
- 建立 Docker image
- 預設直接啟動 Docker 版 OCR

===========================================================================================================================================

### 安裝 Docker 版但先不要啟動

執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\install_paddle_ocr_docker.ps1 -NoAutoStart
```

===========================================================================================================================================

### 只啟動 Docker 版 OCR

- 雙擊 `distribution_tools\start_ocr_launcher_docker.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\distribution_tools\start_ocr_launcher_docker.ps1
```

===========================================================================================================================================

### Docker 版的重要提醒

- 目前 Docker 版是 CPU 版映像，重點是穩定與環境隔離。
- 第一次建立 image 會花比較久，因為要下載基底映像和 Python 套件。
- Docker 模型快取會保存在 `.docker_data\paddlex\official_models`。
- OCR 仍會直接讀寫你主機上的專案資料夾，不會把輸出困在 container 裡。
- Docker Desktop 需要 Linux containers 模式。

===========================================================================================================================================

### EXE 打包的重要提醒

EXE 會承接目前 `.venv` 的 runtime 類型。

- 如果目前 `.venv` 是 GPU 版，目標電腦仍然需要相容的 GPU / CUDA 環境。
- 如果你想要更高的相容性，請從 CPU 版 `.venv` 建立 EXE。
- EXE 版本預設會掃描 EXE 所在資料夾。
- `one-folder` 比較適合長期使用與較大的模型集合。
- `one-file` 比較方便攜帶，但每次執行都要先解壓，內含模型時尤其明顯。

### 目標電腦上的使用方式

1. 將 ZIP 解壓到短且可寫入的資料夾，例如 `D:\PaddleOCR`
2. 如果該資料夾中已經有舊的 `.venv`，請先刪除
3. 執行 `install_paddle_all.bat`
4. 讓安裝程式在該電腦上重新建立環境

如果打包中包含 `bundled_wheels`，請保持它與 `tools\install_paddle_ocr_suite.ps1` 所在的整個資料夾結構一起移動，不要只單獨搬 `tools\` 裡的檔案。
不要只搬移解壓後的一部分檔案，否則安裝程式會失去對本機 wheel 檔的存取。
如果這包 ZIP 是用 `-GpuOnlyWheelhouse` 建立的，目標電腦也必須具備可用的 GPU 執行環境，因為安裝程式不會再回退到 CPU。
如果你仍然必須解壓到很長的路徑下，安裝程式現在會嘗試在安裝時暫時重新對應到較短的磁碟代號。

===========================================================================================================================================

## PP-StructureV3 座標疊圖檢視器

根目錄的 `ppstructurev3_overlay_viewer.html` 是一個本機單檔檢視器，用來把 `PP-StructureV3 coordinate mode` 輸出的座標 TXT 疊回原圖上檢查。

**適合用途**

- 快速檢查 `PP-StructureV3` 的文字框、版面框有沒有貼準。
- 比對 OCR 結果和原圖是否有位移、縮放不一致或漏抓。
- 在不開 Python、不中轉 JSON 的情況下，直接用瀏覽器看疊圖結果。

**使用前提**

- TXT 必須是開啟 `PP-StructureV3 coordinate mode` 後產生的 `*.ppstructurev3.txt`。
- 最穩定的做法是把圖片和對應 TXT 放在同一批資料夾裡，再整個資料夾一起載入。
- 直接雙擊 `ppstructurev3_overlay_viewer.html` 即可使用，不需要另外啟動本機伺服器。

**基本使用方式**

1. 開啟 `ppstructurev3_overlay_viewer.html`。
2. 按「選擇資料夾」，或直接把整個資料夾拖進頁面。
3. 左側會列出圖片清單；點選任一圖片後，頁面會自動嘗試配對同資料夾的 `*.ppstructurev3.txt`。
4. 右側會把文字框、文字內容，或版面框疊在原圖上顯示。

**支援的配對方式**

- `image01.jpg` 對 `image01.ppstructurev3.txt`
- `specs__page1.jpg` 對 `specs__page1.ppstructurev3.txt`
- OCR 輸出採用「相對路徑以 `__` 串接」的命名時，檢視器也會自動嘗試配對

**檢視操作**

- 滑鼠滾輪：縮放圖片與疊圖
- 按住左鍵拖曳：平移畫面
- 雙擊檢視區：回到自動 fit 的初始視角
- `顯示文字框 / 顯示文字內容 / 顯示版面框`：切換不同疊圖資訊
- `字體倍率 / 框線透明度`：調整閱讀性

**疊圖微調**

- `整體縮放`：整體放大或縮小 OCR 疊圖層
- `水平比例 / 垂直比例`：只修正寬或高的比例誤差
- `X 位移 / Y 位移`：把整個疊圖層往左右或上下平移
- `重設目前圖片校正`：只重設目前選取圖片的微調數值

建議順序是先調 `整體縮放`，再補 `X/Y 位移`；只有在寬和高的比例本身不一致時，才去微調 `水平比例` 或 `垂直比例`。

**注意事項**

- 如果只拖圖片、沒有把對應 TXT 一起選進來，瀏覽器不能自動偷看同資料夾裡未選取的本機檔案。
- 這個檢視器目前是以 `PP-StructureV3` 座標 TXT 為主，不是拿來看 `PP-OCRv5` 的一般 TXT。
- 若某張圖片顯示「沒有對應的 ppstructurev3 TXT」，通常是命名沒有配上，或那張圖的 OCR 尚未用座標模式輸出。

===========================================================================================================================================

## 輸出檔命名

產出的檔名會包含相對資料夾路徑，以降低同名檔案衝突的機率。

範例：

- 來源：`specs/v1/report.pdf`
- 輸出：`specs__v1__report.ppocrv5.txt`

===========================================================================================================================================

## 安裝器維護向更新

- 安裝器現在會同時顯示 `Detected system Python` 與 `Using venv Python`。
- 新增選項：`-StrictVenvPythonMatch`，只有在 `.venv` 的 Python major.minor 與偵測到的系統 Python 相同時才重用，否則會重建 `.venv`。
- 安裝器啟動時現在會設定 `PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True`，讓早期的 Paddle / PaddleOCR 檢查更安靜。

===========================================================================================================================================

## 這個版本的其他修正

- 安裝器現在會驗證 `PP-StructureV3` 是否真的能成功實例化；如果不行，會自動安裝 `paddlex[ocr]==3.4.2`。
- 主安裝器現在要求 `PP-OCRv5` 與 `PP-StructureV3` 兩者都必須安裝並驗證成功，不再接受只完成 OCR 的半套環境。
- 啟動器現在會在遞迴掃描時排除 `.venv`、`venv`、`__pycache__`、`.git`、`_pdf_pages` 與 `node_modules`。

===========================================================================================================================================
## 新的互動式輸出選項

啟動器現在的互動順序如下：

- 所有可調數值的題目，現在都會依「由小到大，最後一個是 `Custom`」的順序顯示，並在目前預設的那一項後面標示 `[預設值]`。

1. `Choose file types to scan`
   - 選擇掃描圖片、PDF，或兩者都掃。
2. `Choose mode`
   - `PP-OCRv5`、`PP-StructureV3`，或兩種都跑。
3. `Choose device`
   - 選擇 `Auto / CPU / GPU`。
   - 中文說明會提示：這主要影響速度與穩定性，不直接改辨識品質。
4. `Choose PDF DPI`
   - 只在本次有掃描 PDF 時出現。
   - 中文說明會提示：DPI 越高，小字通常越容易辨識，但速度更慢、記憶體使用更高。
5. `Choose text_det_limit_side_len`
   - 文字偵測前輸入影像的邊長上限。
   - 中文說明會提示：設大一點較有利小字與高解析圖片，但速度較慢。
6. `Choose text_det_thresh`
   - 文字區域偵測門檻。
   - 中文說明會提示：設低一點較容易抓到淡字或模糊字，但誤抓也可能增加。
7. `Choose text_det_box_thresh`
   - 文字框保留門檻。
   - 中文說明會提示：設高一點只保留更有把握的框；設低一點會保留更多框。
8. `Choose text_det_unclip_ratio`
   - 文字框外擴比例。
   - 中文說明會提示：設大一點較不容易切掉文字邊緣，但太大可能讓相鄰文字黏在一起。
9. `Choose text_rec_score_thresh`
   - 模型內部的文字辨識信心門檻。
   - 中文說明會提示：設高一點更保守、低信心文字更容易被捨棄。
10. `Choose final confidence threshold`
    - 程式最後輸出前的再篩選門檻。
    - 中文說明會提示：這和 `text_rec_score_thresh` 不同，這一題是最後輸出前才套用。
11. `Choose layout_threshold`
    - 只在 `PP-StructureV3` 或 `Run both` 時出現。
    - 中文說明會提示：這是版面區塊偵測門檻；設低一點抓更多區塊，設高一點更保守。
12. `PP-StructureV3 coordinate mode`
    - 只在 `PP-StructureV3` 或 `Run both` 時出現。
    - 可選是否輸出文字與版面框座標。
    - 中文說明會提示：這不會提升辨識品質，只是讓輸出內容更完整，方便疊圖、標註與後處理。
13. `Choose TXT output layout`
    - `One TXT per image / PDF`
    - `One <folder>knowledgebase.txt per folder`
14. `Choose output format`
    - `TXT only`
    - `TXT + JSON`

補充差異：

- `text_rec_score_thresh`：模型內部的辨識信心門檻。
- `final confidence threshold`：模型跑完之後，程式最後輸出前再篩一次的門檻。
- `TXT only`：只輸出 TXT。
- `TXT + JSON`：會額外保留每個檔案的 JSON；若使用 knowledgebase 模式，也會輸出對應的 JSONL。
