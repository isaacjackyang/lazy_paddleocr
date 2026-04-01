# OCR 套件打包說明

## 這個版本的變更
- 預設安裝模式為 GPU。
- 若相容，會重用既有的 `.venv`。
- 若相容，會重用既有的 PaddlePaddle。
- 若相容，會重用既有的 PaddleOCR / PyMuPDF。
- 如果 GPU 安裝或檢查失敗，安裝程式會自動回退到 CPU。
- 啟動器預設會遞迴掃描子資料夾。
- 如果你只想掃描目前資料夾，請使用 `-NoRecursive`。

## 一般使用方式
1. 雙擊 `install_and_start.bat`
2. 或執行 `install_paddle_ocr_suite.ps1`
3. 啟動後依提示選擇 OCR 模式與信心分數門檻

如果安裝在完成前中斷，安裝程式現在會顯示手動修復清單，並把相同的 PowerShell 指令寫入 `install_manual_recovery.ps1`。

## 根目錄腳本總覽

### 一般使用者最常用的入口
- `install_and_start.bat`：最簡單的本機安裝入口。它只是包裝 `install_paddle_ocr_suite.ps1`，適合雙擊執行。
- `start_ocr_launcher.bat`：最簡單的本機啟動入口。它只是包裝 `start_ocr_launcher.ps1`，適合環境已經裝好後再次執行 OCR。
- `install_and_start_docker.bat`：最簡單的 Docker 安裝入口。它只是包裝 `install_paddle_ocr_docker.ps1`。
- `start_ocr_launcher_docker.bat`：最簡單的 Docker 啟動入口。它只是包裝 `start_ocr_launcher_docker.ps1`。

### 本機 Python / venv 版核心腳本
- `install_paddle_ocr_suite.ps1`：本機版主安裝腳本。負責建立或修復 `.venv`、安裝 PaddlePaddle / PaddleOCR / PyMuPDF / PP-StructureV3 依賴，必要時自動從 GPU 回退到 CPU。
- `start_ocr_launcher.ps1`：本機版主啟動腳本。負責檢查環境、轉交參數、啟動互動式 OCR 流程。
- `run_ocr_launcher.py`：實際執行 OCR 掃描、建立模型 pipeline、輸出 TXT / JSON 的 Python 核心。一般情況不需要直接手動執行，通常由 `start_ocr_launcher.ps1` 呼叫。
- `install_manual_recovery.ps1`：由 `install_paddle_ocr_suite.ps1` 在安裝失敗時自動產生的手動修復清單。這不是固定內容的長期維護腳本，而是針對當次失敗狀況輸出的補救指令。

### Doc parser / VL 元件安裝腳本
- `install_paddle_doc_parser_component.ps1`：這一組元件的通用安裝核心。會依 `-Target` 決定安裝 `PP-StructureV3`、`PaddleOCR-VL-1.5` 或 `PaddleOCR-VL`，並負責共用的 `.venv`、PaddlePaddle 與 `paddleocr[doc-parser]` 安裝流程。
- `install_pp_structurev3.ps1`：`PP-StructureV3` 的簡化入口。它只是幫你把 `-Target ppstructurev3` 傳給 `install_paddle_doc_parser_component.ps1`。
- `install_paddleocr_vl_1_5.ps1`：`PaddleOCR-VL-1.5` 的簡化入口。它只是幫你把 `-Target paddleocr-vl-1.5` 傳給 `install_paddle_doc_parser_component.ps1`。
- `install_paddleocr_vl.ps1`：`PaddleOCR-VL`（`pipeline_version="v1"`）的簡化入口。它只是幫你把 `-Target paddleocr-vl` 傳給 `install_paddle_doc_parser_component.ps1`。

### Docker 版腳本
- `install_paddle_ocr_docker.ps1`：Docker 版主安裝腳本。負責檢查或安裝 Docker Desktop、建立 image、準備模型快取。
- `start_ocr_launcher_docker.ps1`：Docker 版主啟動腳本。用 container 執行 OCR，並把目前資料夾掛載進容器。

### 打包與發佈腳本
- `build_portable_bundle.ps1`：建立攜帶式 ZIP 的主腳本。可選擇是否把模型快取與 wheelhouse 一起打包。
- `build_portable_bundle.bat`：`build_portable_bundle.ps1` 的雙擊入口，使用預設的精簡打包參數。
- `build_full_portable_bundle.bat`：完整攜帶包的雙擊入口，會自動加上 `-IncludeModelCache -IncludeWheelhouse`。
- `build_onefolder_exe.ps1`：建立 one-folder EXE 的主腳本。
- `build_onefolder_exe.bat`：`build_onefolder_exe.ps1` 的雙擊入口。
- `build_onefile_exe.ps1`：建立 one-file EXE 的主腳本。
- `build_onefile_exe.bat`：`build_onefile_exe.ps1` 的雙擊入口。

### 補充說明
- `.bat` 檔大多只是給 Windows 使用者雙擊的入口，本體邏輯通常都在對應的 `.ps1`。
- 若你在看哪支腳本該改、該除錯、該加功能，優先看 `.ps1` 與 `run_ocr_launcher.py`。
- 若你只是要使用，不需要逐一理解所有腳本；通常只會碰到 `install_and_start.bat`、`start_ocr_launcher.bat`、或 Docker 對應的兩支 `.bat`。

## PowerShell 腳本指南

### `install_paddle_ocr_suite.ps1`
這是主要的安裝腳本，用來建立、修復或重建本機 OCR 環境。

功能：
- 建立或重用 `.venv`
- 安裝 PaddlePaddle、PaddleOCR、PyMuPDF 與 PP-StructureV3 相依套件
- 預設使用 GPU 模式，但若 GPU 安裝或驗證失敗會自動回退到 CPU
- 安裝完成後可選擇直接啟動 OCR 啟動器

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddle_ocr_suite.ps1
```

常用參數：
- `-Mode gpu` 或 `-Mode cpu`：選擇偏好的安裝模式
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`：指定 Paddle GPU 套件來源版本
- `-StrictVenvPythonMatch`：如果 `.venv` 的 Python major.minor 與偵測到的系統 Python 不一致，就重建 `.venv`
- `-NoAutoStart`：只安裝，不在完成後自動啟動 OCR

適合使用時機：
- 這台電腦尚未完成環境安裝
- `.venv` 損壞或遺失
- 你想切換成 CPU 優先或 GPU 優先的安裝行為

====================================

### `start_ocr_launcher.ps1`
這是 OCR 啟動腳本，適合在環境已經準備好的情況下直接執行，不會進行套件安裝。

功能：
- 檢查 `.venv\Scripts\python.exe` 與 `run_ocr_launcher.py` 是否存在
- 依指定掃描設定啟動 OCR 啟動器
- 預設使用遞迴掃描

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\start_ocr_launcher.ps1
```

常用參數：
- `-Root <folder>`：指定要掃描的資料夾，而不是使用專案資料夾
- `-NoRecursive`：只掃描目前資料夾，不遞迴
- `-Device Auto|CPU|GPU`：指定執行裝置；遇到不支援的 GPU 時可強制使用 CPU
- `-PdfDpi 200`：調整 PDF 轉圖 DPI
- `-KeepPdfImages`：保留 PDF 轉出的頁面圖片
- `-ImageExts` / `-PdfExts`：覆寫副檔名過濾條件

適合使用時機：
- 安裝已經完成
- 你只想再次執行 OCR，不想重跑安裝流程

====================================

### `install_paddle_doc_parser_component.ps1`
這是 `PP-StructureV3`、`PaddleOCR-VL-1.5`、`PaddleOCR-VL` 共用的安裝核心腳本，通常作為底層工具使用。

功能：
- 建立或重用 `.venv`
- 安裝 PaddlePaddle（GPU 失敗時自動回退到 CPU）
- 安裝 `paddleocr[doc-parser]` 相關依賴
- 依 `-Target` 切換驗證流程，確認指定元件可匯入或可初始化

使用方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddle_doc_parser_component.ps1 -Target ppstructurev3
```

常用參數：
- `-Target ppstructurev3` / `paddleocr-vl-1.5` / `paddleocr-vl`
- `-Mode gpu` 或 `-Mode cpu`
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`
- `-VenvDir .venv`

適合使用時機：
- 你想用一支共用腳本處理不同 doc parser 元件
- 你正在維護這個專案，想把安裝邏輯集中在單一地方修改

====================================

### `install_manual_recovery.ps1`
這是安裝失敗後自動產生的手動修復腳本，不是平常主要執行的入口。

功能：
- 記錄當次安裝失敗時建議你補跑的指令
- 方便你逐步手動安裝或驗證環境
- 讓你在安裝中斷後，不需要回頭翻終端輸出找指令

注意：
- 內容會隨每次失敗情況改變
- 它是診斷與補救腳本，不建議當成固定安裝流程長期依賴

====================================

### `install_pp_structurev3.ps1`
這是專門安裝 `PP-StructureV3` 的 PowerShell 腳本，也是 `install_paddle_doc_parser_component.ps1` 的簡化入口。

功能：
- 建立或重用 `.venv`
- 安裝 PaddlePaddle（GPU 失敗時自動回退到 CPU）
- 安裝 `paddleocr[doc-parser]` 相關依賴
- 以 CPU 模式驗證 `PP-StructureV3` 可成功初始化

使用方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_pp_structurev3.ps1
```

常用參數：
- `-Mode gpu` 或 `-Mode cpu`：選擇偏好的 PaddlePaddle 安裝模式
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`：指定 GPU wheel 來源
- `-VenvDir .venv`：指定虛擬環境資料夾

====================================

### `install_paddleocr_vl_1_5.ps1`
這是專門安裝 `PaddleOCR-VL-1.5` 客戶端環境的 PowerShell 腳本，也是 `install_paddle_doc_parser_component.ps1` 的簡化入口。

功能：
- 建立或重用 `.venv`
- 安裝 PaddlePaddle（GPU 失敗時自動回退到 CPU）
- 安裝 `paddleocr[doc-parser]` 相關依賴
- 驗證 `PaddleOCRVL` 類別可匯入，且支援 `pipeline_version="v1.5"`

使用方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddleocr_vl_1_5.ps1
```

常用參數：
- `-Mode gpu` 或 `-Mode cpu`
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`
- `-VenvDir .venv`

注意：
- 這支腳本準備的是本機 `doc-parser` 客戶端依賴。
- `PaddleOCR-VL-1.5` 的模型權重通常會在第一次實際推論時下載。
- 如果你之後要接 `vLLM` / `SGLang` 等 GenAI server backend，仍需另外安裝對應後端。

====================================

### `install_paddleocr_vl.ps1`
這是專門安裝 `PaddleOCR-VL`（`pipeline_version="v1"`）客戶端環境的 PowerShell 腳本，也是 `install_paddle_doc_parser_component.ps1` 的簡化入口。

功能：
- 建立或重用 `.venv`
- 安裝 PaddlePaddle（GPU 失敗時自動回退到 CPU）
- 安裝 `paddleocr[doc-parser]` 相關依賴
- 驗證 `PaddleOCRVL` 類別可匯入，且接受 `pipeline_version="v1"`

使用方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddleocr_vl.ps1
```

常用參數：
- `-Mode gpu` 或 `-Mode cpu`
- `-Cuda cu118` / `cu126` / `cu129` / `cu130`
- `-VenvDir .venv`

注意：
- 這支腳本同樣安裝的是本機 `doc-parser` 客戶端依賴。
- 實際第一次推論時，模型權重仍可能另外下載。

====================================

### `install_paddle_ocr_docker.ps1`
這是 Docker 版的一鍵安裝腳本，會盡量沿用目前 `install + start` 的操作感。

功能：
- 如果還沒安裝 Docker Desktop，會嘗試用 `winget` 安裝
- 啟動 Docker Desktop 並等待 Docker engine 就緒
- 建立 Docker 專用的模型快取資料夾
- 建立 Docker OCR 映像檔
- 預設安裝完成後直接啟動 Docker 版 OCR launcher

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddle_ocr_docker.ps1
```

常用參數：
- `-NoAutoStart`：安裝完成後不要立刻啟動
- `-ForceRebuild`：強制重建 Docker image
- `-ImageTag`：指定 Docker image 名稱

適合使用時機：
- 你想避開本機 Python / venv / Paddle 版本污染
- 你想把 OCR 執行環境隔離在 Docker 內

====================================

### `start_ocr_launcher_docker.ps1`
這是 Docker 版的 OCR 啟動腳本，互動流程和原本 `start_ocr_launcher.ps1` 類似。

功能：
- 用 Docker container 啟動 `run_ocr_launcher.py`
- 直接掛載目前專案資料夾，讓 OCR 輸出仍寫回主機
- 將 Docker 版模型快取保存在 `.docker_data\paddlex\official_models`

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\start_ocr_launcher_docker.ps1
```

常用參數：
- `-Root <folder>`：指定要掃描的資料夾
- `-NoRecursive`：只掃描目前資料夾，不遞迴
- `-PdfDpi 200`：調整 PDF 轉圖 DPI

適合使用時機：
- Docker image 已建立完成
- 你要用 Docker 隔離環境來跑互動式 OCR

====================================

### `build_portable_bundle.ps1`
這是建立攜帶式 ZIP 的打包腳本，輸出到 `dist\`。如果你要搬到另一台電腦，這是主要的完整攜帶包腳本。

可包含內容：
- 安裝腳本與啟動腳本
- 模型快取
- 從目前 `.venv` 匯出的 wheel 檔

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_portable_bundle.ps1 -IncludeModelCache -IncludeWheelhouse
```

常用參數：
- `-IncludeModelCache`：包含 `%USERPROFILE%\.paddlex\official_models`
- `-IncludeWheelhouse`：包含本機 wheel 檔，降低目標電腦對網路下載的依賴
- `-IncludeTests`：包含測試檔案
- `-IncludeScreenshots`：包含 `Screenshots` 資料夾

適合使用時機：
- 你想產生最完整的攜帶式 ZIP
- 目標電腦可能不容易下載套件或模型

====================================

### `build_onefolder_exe.ps1`
這是建立 one-folder EXE 的打包腳本，輸出到 `dist_exe\`。

功能：
- 使用 PyInstaller 建立真正的 Windows `.exe`
- 把目前 `.venv` 中的 Python 執行環境與 OCR 相依套件一起打包
- 可選擇把 PaddleX 模型快取也一起帶入

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefolder_exe.ps1
```

常用參數：
- `-IncludeModelCache`：把模型快取一起打進 EXE 資料夾
- `-OutputDir`：指定輸出資料夾
- `-BundleName`：指定產出包名稱

適合使用時機：
- 你要的是可直接執行的 EXE 資料夾，而不是 ZIP 安裝包
- 目標電腦預期直接執行打包好的環境

====================================

### `build_onefile_exe.ps1`
這是建立 one-file EXE 的打包腳本，輸出到 `dist_exe\`。

功能：
- 使用 PyInstaller 建立單一 `.exe`
- 可選擇把 PaddleX 模型快取一起嵌入到同一個檔案中
- 執行時會先解開到暫存目錄，再啟動 OCR

常用執行方式：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefile_exe.ps1
```

常用參數：
- `-IncludeModelCache`：把模型快取一起嵌入單檔 EXE
- `-OutputDir`：指定輸出資料夾
- `-BundleName`：指定產出檔名開頭

適合使用時機：
- 你要的是單一 `.exe`，不想另外帶一整個資料夾
- 你可以接受每次啟動前會先解壓到暫存目錄
- 如果加入模型快取，檔案會非常大，啟動也會更慢

## 攜帶式 ZIP 打包流程
如果你要把這個專案搬到另一台電腦，請使用攜帶式 ZIP 打包。

### 建立精簡版攜帶式 ZIP
- 雙擊 `build_portable_bundle.bat`
- 或執行 `build_portable_bundle.ps1`

它會在 `dist\` 建立乾淨的 ZIP，包含啟動與安裝腳本，但不包含：
- `.venv`
- 安裝紀錄檔
- 產生的 OCR 輸出檔
- `Screenshots`

====================================

### 為另一台電腦建立較完整的攜帶式 ZIP
如果目標電腦常在 `wheel` / `pip` 安裝時出問題，建議建立完整版：

- 雙擊 `build_full_portable_bundle.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_portable_bundle.ps1 -IncludeModelCache -IncludeWheelhouse
```

這個版本會額外包含：
- `bundled_model_cache\official_models`
- `bundled_wheels`

安裝程式會：
- 自動匯入隨包提供的模型快取
- 優先使用本機 wheel，再考慮走網路下載
- 優先選擇與建立 wheelhouse 時相同的 Python major.minor 版本

====================================

### 建立包含模型快取的攜帶式 ZIP
執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_portable_bundle.ps1 -IncludeModelCache
```

如果來源電腦存在 `%USERPROFILE%\.paddlex\official_models`，ZIP 內會將其打包到 `bundled_model_cache\official_models`。
在目標電腦上，`install_paddle_ocr_suite.ps1` 會在安裝檢查前自動匯入缺少的模型快取。

====================================

### 建立只包含本機 wheel 的攜帶式 ZIP
執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_portable_bundle.ps1 -IncludeWheelhouse
```

這需要本機已有可用的 `.venv`，因為 wheelhouse 是從目前環境匯出的。

## One-folder EXE 打包流程
如果你要的是可直接執行的資料夾與真正的 `exe`，請使用 one-folder builder。

### 建立 one-folder EXE
- 雙擊 `build_onefolder_exe.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefolder_exe.ps1
```

它會在 `dist_exe\` 建立一個資料夾，內容包含：
- `PaddleOCRLauncher_... .exe`
- 打包後的 Python runtime 檔案
- 目前 `.venv` 中的 Paddle / PaddleOCR / PaddleX 相依套件

====================================

### 建立包含模型快取的 one-folder EXE
執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefolder_exe.ps1 -IncludeModelCache
```

如果建立機器上存在 `%USERPROFILE%\.paddlex\official_models`，它會一起被打包進 EXE 資料夾。
第一次執行時，啟動器會把缺少的內建模型匯入到：
`%USERPROFILE%\.paddlex\official_models`

====================================

## One-file EXE 打包流程
如果你要的是單一 `.exe`，請使用 one-file builder。

### 建立 one-file EXE
- 雙擊 `build_onefile_exe.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefile_exe.ps1
```

它會在 `dist_exe\` 建立一個單獨的 `.exe`。
這個版本不會在輸出資料夾再放一整個 runtime 資料夾，但執行時仍會先解壓到系統暫存目錄。

====================================

### 建立包含模型快取的 one-file EXE
執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build_onefile_exe.ps1 -IncludeModelCache
```

如果建立機器上存在 `%USERPROFILE%\.paddlex\official_models`，它會一起被嵌入 EXE。
這樣比較接近離線可用，但檔案大小會顯著增加，而且每次啟動都會更慢。

====================================

## Docker 版安裝與啟動流程
如果你想避開本機 Python / Paddle 環境衝突，可以改用 Docker 版。

### 一鍵安裝並啟動 Docker 版 OCR
- 雙擊 `install_and_start_docker.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddle_ocr_docker.ps1
```

這支腳本會：
- 嘗試安裝 Docker Desktop
- 等 Docker engine 可用
- 建立 Docker image
- 預設直接啟動 Docker 版 OCR

====================================

### 安裝 Docker 版但先不要啟動
執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install_paddle_ocr_docker.ps1 -NoAutoStart
```

====================================

### 只啟動 Docker 版 OCR
- 雙擊 `start_ocr_launcher_docker.bat`
- 或執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\start_ocr_launcher_docker.ps1
```

====================================

### Docker 版的重要提醒
- 目前 Docker 版是 CPU 版映像，重點是穩定與環境隔離。
- 第一次建立 image 會花比較久，因為要下載基底映像和 Python 套件。
- Docker 模型快取會保存在 `.docker_data\paddlex\official_models`。
- OCR 仍會直接讀寫你主機上的專案資料夾，不會把輸出困在 container 裡。
- Docker Desktop 需要 Linux containers 模式。

====================================

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
3. 執行 `install_and_start.bat`
4. 讓安裝程式在該電腦上重新建立環境

如果打包中包含 `bundled_wheels`，請保持它與 `install_paddle_ocr_suite.ps1` 放在同一層。
不要只搬移解壓後的一部分檔案，否則安裝程式會失去對本機 wheel 檔的存取。
如果你仍然必須解壓到很長的路徑下，安裝程式現在會嘗試在安裝時暫時重新對應到較短的磁碟代號。

## 輸出檔命名
產出的檔名會包含相對資料夾路徑，以降低同名檔案衝突的機率。

範例：
- 來源：`specs/v1/report.pdf`
- 輸出：`specs__v1__report.ppocrv5.txt`

## 安裝器維護向更新

- 安裝器現在會同時顯示 `Detected system Python` 與 `Using venv Python`。
- 新增選項：`-StrictVenvPythonMatch`，只有在 `.venv` 的 Python major.minor 與偵測到的系統 Python 相同時才重用，否則會重建 `.venv`。
- 安裝器啟動時現在會設定 `PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True`，讓早期的 Paddle / PaddleOCR 檢查更安靜。

## 這個版本的其他修正

- 安裝器現在會驗證 `PP-StructureV3` 是否真的能成功實例化；如果不行，會自動安裝 `paddlex[ocr]==3.4.2`。
- 啟動器現在會在遞迴掃描時排除 `.venv`、`venv`、`__pycache__`、`.git`、`_pdf_pages` 與 `node_modules`。

## 新的互動式輸出選項

啟動器現在會詢問你要：
- 僅輸出 TXT
- 輸出 TXT + JSON

若選擇僅輸出 TXT，則每個檔案的 JSON 與 knowledgebase JSONL 檔都會略過。
