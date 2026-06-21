# Lazy PaddleOCR Agent 使用說明

這份文件給 Hermes、Codex、排程器、批次腳本或其他 agent 使用。重點是：不要走互動式 CMD 問答，也不要開 GUI；請直接呼叫非互動 CLI。

## 1. 推薦入口

在專案根目錄執行：

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py --non-interactive --root "D:\input_docs"
```

最推薦的穩定預設：

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\input_docs" `
  --recursive `
  --scan-target pictures_pdf `
  --mode auto `
  --output-mode txt_json `
  --device auto
```

`--mode auto` 是給 agent 最省心的模式：

| 輸入類型 | 自動使用 | 輸出 |
| --- | --- | --- |
| 圖片 | PP-OCRv6 | `*.ppocrv6.txt` + `*.ppocrv6.json` |
| PDF | PP-StructureV3 | `*.ppstructurev3.md` + `*.ppstructurev3.json` |

## 2. Agent 應該怎麼選模式

最穩定的懶人策略：

```powershell
--mode auto --scan-target pictures_pdf --output-mode txt_json
```

如果 agent 已經知道資料類型，可以更精準：

| 需求 | 建議參數 |
| --- | --- |
| 大量圖片轉純文字 | `--scan-target pictures --mode ppocrv6` |
| PDF 轉 Markdown / RAG ingest | `--scan-target pdf --mode ppstructurev3` |
| 圖片和 PDF 混在一起 | `--scan-target pictures_pdf --mode auto` |
| 想同時比較 V6 與 V3 結果 | `--mode both` |
| 只要文字，不要 JSON | `--output-mode txt_only` |
| 需要座標檢查 | `--mode ppstructurev3 --structure-coordinate-mode` |

## 3. 完整常用命令

### 3.1 圖片資料夾 OCR

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\images" `
  --recursive `
  --scan-target pictures `
  --mode ppocrv6 `
  --output-mode txt_json `
  --device auto
```

### 3.2 PDF 轉 Markdown

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\pdfs" `
  --recursive `
  --scan-target pdf `
  --mode ppstructurev3 `
  --output-mode txt_json `
  --device auto
```

### 3.3 混合資料夾，自動路由

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\docs" `
  --recursive `
  --scan-target pictures_pdf `
  --mode auto `
  --output-mode txt_json `
  --device auto
```

### 3.4 CPU 強制模式

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\docs" `
  --recursive `
  --scan-target pictures_pdf `
  --mode auto `
  --device cpu
```

### 3.5 指定 GPU

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\docs" `
  --recursive `
  --scan-target pictures_pdf `
  --mode auto `
  --device gpu `
  --gpu-id 0
```

## 4. 參數表

| 參數 | 可用值 / 範例 | 說明 |
| --- | --- | --- |
| `--non-interactive` | flag | 必加。關閉互動式問題。 |
| `--root` | `"D:\docs"` | 要處理的資料夾。 |
| `--recursive` | flag | 包含子目錄。 |
| `--scan-target` | `pictures`, `pdf`, `pictures_pdf` | 掃描圖片、PDF 或兩者。 |
| `--mode` | `auto`, `ppocrv6`, `ppstructurev3`, `both` | 處理模式。agent 建議 `auto`。 |
| `--output-mode` | `txt_json`, `txt_only` | 是否輸出 JSON。 |
| `--text-output-layout` | `per_file`, `knowledgebase` | 每檔輸出或每資料夾 knowledgebase。 |
| `--device` | `auto`, `cpu`, `gpu` | 執行裝置。 |
| `--gpu-id` | `0`, `1` | 指定 GPU 編號。 |
| `--pdf-dpi` | `200`, `300` | PP-OCRv6 處理 PDF 時的渲染 DPI。V3 直接吃 PDF 時通常不用調。 |
| `--keep-pdf-images` | flag | 保留 PDF 渲染頁面圖片。 |
| `--image-exts` | `.jpg,.png,.webp` | 自訂圖片副檔名。 |
| `--pdf-exts` | `.pdf` | 自訂 PDF 副檔名。 |

## 5. 模型與後端參數

預設：

```powershell
--ocr-engine paddle_static
--text-detection-model PP-OCRv6_medium_det
--text-recognition-model PP-OCRv6_medium_rec
```

可選模型：

| 類型 | 建議值 |
| --- | --- |
| Detection 高品質 | `PP-OCRv6_medium_det` |
| Detection 平衡 | `PP-OCRv6_small_det` |
| Detection 快速 | `PP-OCRv6_tiny_det` |
| Recognition 高品質 | `PP-OCRv6_medium_rec` |
| Recognition 平衡 | `PP-OCRv6_small_rec` |
| Recognition 快速 | `PP-OCRv6_tiny_rec` |

可選後端：

| 後端 | 說明 |
| --- | --- |
| `paddle_static` | 預設，最推薦。 |
| `onnxruntime` | 可測試用，需確認模型與環境相容。 |
| `paddle` | Paddle dynamic backend。 |
| `transformers` | 特定模型情境才需要。 |

Agent 若沒有特殊理由，請使用 `paddle_static + medium_det + medium_rec`。

## 6. 輸出檔案

預設輸出在來源檔案同資料夾。

圖片走 PP-OCRv6：

```text
source.png
source.ppocrv6.txt
source.ppocrv6.json
```

PDF 走 PP-StructureV3：

```text
source.pdf
source.ppstructurev3.md
source.ppstructurev3.json
```

若來源在子目錄，輸出檔名會把相對路徑用 `__` 串起來，避免同名檔互相覆蓋。

`--output-mode txt_only` 只會保留文字或 Markdown，並刪除同名 JSON。

`--text-output-layout knowledgebase` 會改成每個資料夾輸出：

```text
<folder>knowledgebase.txt
<folder>knowledgebase.jsonl
```

## 7. 回傳碼與 agent 判斷

目前 CLI 的主要行為：

| 狀況 | 行為 |
| --- | --- |
| 沒有找到檔案 | 印出 `No matching files were found. Nothing to do.`，結束。 |
| 單檔失敗 | 該檔輸出錯誤文字或錯誤 JSON，批次繼續。 |
| pipeline 初始化失敗 | 該 mode skipped，最後摘要列出 failed mode。 |
| GPU 初始化失敗且 `--device auto` | 會嘗試 fallback CPU。 |
| GPU OOM / oneDNN runtime 問題 | 會重建 CPU pipeline retry。 |

Hermes 建議判斷：

1. 先看 process exit code。
2. 再掃 stdout 是否有 `[INIT FAIL]`、`FAIL ->`、`failed`。
3. 最後檢查目標資料夾是否產生預期的 `.txt`、`.md` 或 `.json`。

## 8. 常見 agent 流程

### 8.1 PDF to Markdown for RAG

1. 建立暫存 input folder。
2. 把 PDF 放進去。
3. 執行：

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\job_input" `
  --scan-target pdf `
  --mode ppstructurev3 `
  --output-mode txt_json `
  --device auto
```

4. 讀取 `*.ppstructurev3.md`。
5. 若需要 metadata，讀取 `*.ppstructurev3.json`。

### 8.2 Images to plain text

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\job_images" `
  --recursive `
  --scan-target pictures `
  --mode ppocrv6 `
  --output-mode txt_only `
  --device auto
```

讀取 `*.ppocrv6.txt`。

### 8.3 Mixed folder ingest

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py `
  --non-interactive `
  --root "D:\mixed_docs" `
  --recursive `
  --scan-target pictures_pdf `
  --mode auto `
  --output-mode txt_json `
  --device auto
```

讀取：

- 圖片結果：`*.ppocrv6.txt`
- PDF 結果：`*.ppstructurev3.md`
- JSON metadata：`*.json`

## 9. PP-OCRv6 vs PP-StructureV3

| 需求 | 建議 |
| --- | --- |
| 圖片 OCR | PP-OCRv6 |
| 掃描 PDF 只要純文字 | PP-OCRv6 或 PP-StructureV3；穩定懶人用 V3 |
| PDF 轉 Markdown | PP-StructureV3 |
| 表格、雙欄、標題層級 | PP-StructureV3 |
| 可選字 PDF 只要文字 | 理想上先抽 PDF text layer；本工具目前 agent 預設用 V3 |
| 大量圖片、速度優先 | PP-OCRv6 small/tiny |

一句話：agent 不想判斷文件類型時，用 `--mode auto`。圖片會快，PDF 會走比較穩的文件結構解析。

## 10. 注意事項

- `Creating model ... Model files already exist` 是正常快取訊息。
- PP-StructureV3 內部可能載入 `PP-OCRv5_server_det/rec`，這是 V3 pipeline 的子模型，不代表圖片 OCR 沒用 V6。
- `No ccache found` 是 Paddle 的 warning，可忽略。
- launcher 會預設設定 `OMP_NUM_THREADS=1`，避免 Paddle 多執行緒警告。
- 如果使用 `--device gpu` 且 GPU 不可用，可能直接失敗；agent 最穩用 `--device auto`。
- 首次執行某些模型時會下載或建立快取，會比後續慢。

## 11. 最小可用命令

給 Hermes 的最短命令：

```powershell
.\.venv\Scripts\python.exe .\tools\run_ocr_launcher.py --non-interactive --root "D:\docs" --recursive --mode auto
```

建議 Hermes 寫入任務紀錄時保存：

- command
- cwd
- stdout
- stderr
- exit code
- generated files list

