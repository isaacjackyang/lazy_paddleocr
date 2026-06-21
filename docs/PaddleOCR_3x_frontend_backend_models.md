# PaddleOCR 3.x 前端、後端、模型整理

更新日期：2026-06-21

這份文件把「Paddle 的前端 / 後端 / 模型」限定在 PaddleOCR 3.x 與 PP-OCRv6 的 OCR 場景。這裡的 Paddle 不是整個 PaddlePaddle 生態，而是本專案會碰到的 PaddleOCR、PaddleX OCR pipeline、PP-StructureV3、PaddleOCR-VL 相關元件。

官方目前最新 GitHub release 顯示為 PaddleOCR v3.7.0，日期是 2026-06-11。PaddleOCR 3.5 開始提供統一的推論引擎設定，3.7.0 已把 ONNX Runtime 納入可切換後端。

參考來源：

- PaddleOCR repository: https://github.com/PaddlePaddle/PaddleOCR
- PaddleOCR General OCR pipeline: https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/OCR.en.md
- PaddleOCR inference engine: https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/inference_deployment/local_inference/inference_engine.en.md
- PaddleX model Python API engine list: https://paddlepaddle.github.io/PaddleX/latest/en/module_usage/instructions/model_python_API.html
- PP-StructureV3 pipeline: https://paddlepaddle.github.io/PaddleX/3.7/en/pipeline_usage/tutorials/ocr_pipelines/PP-StructureV3.html
- PP-OCRv6 safetensors / ONNX model pages: https://huggingface.co/PaddlePaddle

## 一句話總覽

PaddleOCR 可以拆成三層看：

| 層級 | 你會看到的東西 | 負責什麼 |
| --- | --- | --- |
| 前端入口 | CLI、Python API、Module API、Pipeline API、Serving、MCP / Agent wrapper | 使用者或程式怎麼呼叫 OCR |
| 後端推論引擎 | `paddle`、`paddle_static`、`paddle_dynamic`、`transformers`、`onnxruntime` | 模型實際由哪個 runtime 載入與執行 |
| 模型 | PP-OCRv6 det / rec、方向分類、去彎曲、PP-StructureV3、PaddleOCR-VL | 實際做文字偵測、辨識、版面解析、文件理解 |

## 1. 前端入口

前端不是指網頁 UI，而是「怎麼把圖片、PDF 或資料夾送進 PaddleOCR」。

| 入口 | 典型用法 | 適合情境 | 備註 |
| --- | --- | --- | --- |
| CLI | `paddleocr ocr -i image.png` | 手動測試、批次腳本、快速驗證模型 | 最接近本專案 `.bat` / PowerShell launcher 的使用方式 |
| Python API | `from paddleocr import PaddleOCR` | 專案內整合、GUI launcher、服務 wrapper | 適合包成 lazy_paddleocr 的批次處理流程 |
| Module API | `TextDetection`、`TextRecognition` | 只想單獨跑 det 或 rec | 適合診斷瓶頸與客製化流程 |
| Pipeline API | `PaddleOCR`、`PPStructureV3` | 一次跑完整 OCR 或文件解析 | 一般 OCR 用 `PaddleOCR`，PDF / 表格 / Markdown 用 `PPStructureV3` |
| Self-hosted Serving | HTTP API / service | 給 agent、網頁、其他程式呼叫 | 適合把 OCR 固定成 localhost service |
| Browser / Android / iOS | 前端或端側部署 | Web OCR、行動裝置 | 需依官方端側部署能力與模型格式選型 |
| MCP / Agent Skills | agent 工具包裝 | 讓 Hermes / Codex / agent 自動呼叫 OCR | 實務上通常包 CLI 或 HTTP service |

本專案建議：以 Python API 或 CLI wrapper 為主。若要服務化，再把 CLI/Python OCR 包成 localhost API，不要一開始就把整個 PP-StructureV3 或 VLM 直接塞進 agent prompt 流程。

## 2. 後端推論引擎

PaddleOCR 3.5 後可用 `engine` 選擇推論後端。官方列出的主要值如下：

| `engine` | 模型格式 / 生態 | 優點 | 適合情境 |
| --- | --- | --- | --- |
| `None` | 自動 | 保持預設行為，多數情況走 PaddlePaddle | 不想管後端時使用 |
| `paddle` | PaddlePaddle 自動入口 | 依模型檔案自動選 `paddle_static` 或 `paddle_dynamic`，通常偏好 static | 一般 PaddleOCR 使用者 |
| `paddle_static` | `.pdmodel` / `.pdiparams` | 效能與部署調校較成熟，官方常建議作為本地推論首選 | Windows GPU、本機批次 OCR、追求速度 |
| `paddle_dynamic` | `.pdparams` | 彈性高、較方便 debug | 開發、訓練後驗證、研究 |
| `transformers` | `safetensors` / Hugging Face | 容易接 HF 生態與既有工具鏈 | 不想裝完整 PaddlePaddle，或已在 HF/Transformers 環境 |
| `onnxruntime` | `.onnx` | 輕量、跨平台、CPU/GPU 部署彈性好 | 想降低 Paddle 依賴、部署到不同 runtime |

模型格式與後端可簡化成：

| 模型名稱或檔案 | 建議後端 |
| --- | --- |
| Paddle inference model | `paddle` 或 `paddle_static` |
| `*_safetensors` | `transformers` |
| `*_onnx` | `onnxruntime` |
| GGUF | 不適合 PP-OCRv6 det / rec；這不是 llama.cpp 類文字模型 |

效能建議：

- 若本機已能穩定跑 Paddle GPU，先選 `paddle_static`。
- 若想把依賴變薄、部署到非 Paddle 環境，再評估 `onnxruntime`。
- 若正在使用 Hugging Face 生態，或模型只拿得到 safetensors，可選 `transformers`。
- 不建議為 OCR det / rec 追 GGUF。OCR 的偵測與辨識模型不是一般 LLM token generator。

## 3. PP-OCRv6 一般 OCR 模型

General OCR pipeline 不是單一模型，而是多個模組串起來：

| 模組 | 功能 | 常見模型 |
| --- | --- | --- |
| Document orientation classification | 判斷整張文件 0 / 90 / 180 / 270 度 | `PP-LCNet_x1_0_doc_ori` |
| Text image unwarping | 修正彎曲、拍照歪斜、文件形變 | `UVDoc` |
| Text line orientation | 判斷文字行 0 / 180 度 | `PP-LCNet_x0_25_textline_ori`、`PP-LCNet_x1_0_textline_ori` |
| Text detection | 找出文字框 | `PP-OCRv6_medium_det`、`PP-OCRv6_small_det`、`PP-OCRv6_tiny_det` |
| Text recognition | 辨識文字內容 | `PP-OCRv6_medium_rec`、`PP-OCRv6_small_rec`、`PP-OCRv6_tiny_rec` |

### PP-OCRv6 Det

| 模型 | 定位 | 官方模型大小 | 適合情境 |
| --- | --- | --- | --- |
| `PP-OCRv6_medium_det` | 高精度文字偵測 | 59.4 MB | server、GPU、品質優先 |
| `PP-OCRv6_small_det` | 精度與速度平衡 | 9.6 MB | 一般部署、行動端、批次速度 |
| `PP-OCRv6_tiny_det` | 超輕量 | 1.9 MB，0.43M params | edge / IoT / 大量圖片快速粗掃 |

### PP-OCRv6 Rec

| 模型 | 定位 | 官方模型大小 | 適合情境 |
| --- | --- | --- | --- |
| `PP-OCRv6_medium_rec` | 高精度辨識 | 73.3 MB | server、GPU、品質優先 |
| `PP-OCRv6_small_rec` | 平衡型辨識 | 20.4 MB | 一般批次 OCR |
| `PP-OCRv6_tiny_rec` | 超輕量辨識 | 4.4 MB | edge / IoT / 大量圖片快速粗掃 |

官方 PP-OCRv6 介紹指出，v6 是 medium / small / tiny 三層模型家族，涵蓋約 1.5M 到 34.5M 參數規模。medium tier 主打最高準確率，small / tiny 主打部署與速度。

## 4. 舊版與多語模型

PP-OCRv6 是新主線，但實務上仍會遇到 v5 / v4 / v3：

| 類別 | 模型例子 | 什麼時候用 |
| --- | --- | --- |
| v5 detection | `PP-OCRv5_server_det`、`PP-OCRv5_mobile_det` | 既有環境已穩定，暫不升 v6 |
| v4 detection | `PP-OCRv4_server_det`、`PP-OCRv4_mobile_det` | 舊專案相容 |
| v5 recognition | `PP-OCRv5_server_rec`、`PP-OCRv5_mobile_rec` | 已部署 v5 workflow |
| v4 document rec | `PP-OCRv4_server_rec_doc` | 舊文件辨識流程 |
| v3 多語 mobile rec | `korean_PP-OCRv3_mobile_rec`、`japan_PP-OCRv3_mobile_rec`、`chinese_cht_PP-OCRv3_mobile_rec`、`latin_PP-OCRv3_mobile_rec`、`arabic_PP-OCRv3_mobile_rec`、`cyrillic_PP-OCRv3_mobile_rec`、`devanagari_PP-OCRv3_mobile_rec` | 特定語系、舊模型覆蓋較完整時 |

如果沒有相容性包袱，本專案新流程優先看 PP-OCRv6。若使用繁中或多語混合資料，需要實測 v6 與 v3/v5 多語模型的輸出品質，不要只看模型世代。

## 5. 文件解析與 Markdown

如果只是要把圖片中文字拉出來，用 PP-OCRv6 det + rec。若要 PDF 版面、表格、標題、圖片區塊、公式或 Markdown，才進 PP-StructureV3 或 PaddleOCR-VL。

| Pipeline | 負責什麼 | 適合情境 |
| --- | --- | --- |
| General OCR / PP-OCRv6 | 文字偵測 + 文字辨識 | 大量圖片、純文字抽取、速度優先 |
| PP-StructureV3 | layout、OCR、表格、公式、章印、chart parsing、Markdown | PDF、掃描文件、表格與版面結構 |
| PaddleOCR-VL | VLM 文件理解 | 複雜文件、需要跨元素理解，不只 OCR |
| PP-ChatOCRv4 | OCR + 文件理解 + 資訊抽取 | 發票、合約、問答、欄位抽取 |

PP-StructureV3 官方定位是文件 layout parsing，會處理文字區塊、標題、段落、圖片、表格等元素，並可輸出結構化資料與 Markdown。它比一般 OCR 重很多，不適合拿來當所有圖片的第一道處理。

## 6. PDF 類型與支援度

PP-OCRv6 可以吃 PDF，也可以吃圖片型 PDF；但它本質上是 OCR pipeline，不是完整 PDF parser。更精準的判斷是：圖片型 PDF 用 PP-OCRv6 很對路；可選字的文件型 PDF 能跑，但通常不該第一個用 OCR。

| PDF 類型 | PP-OCRv6 支援度 | 是否推薦只用 PP-OCRv6 | 更合理方案 |
| --- | --- | --- | --- |
| 可選字的文件型 PDF / born-digital PDF | 可處理，但不是最優 | 不建議 | 先抽文字層，OCR 只做 fallback |
| 掃描 PDF / 圖片型 PDF | 高度適合 | 可以 | PP-OCRv6 det + rec |
| 複雜版面 PDF：表格、雙欄、圖片、公式、標題層級 | 可 OCR，但結構不足 | 不建議 | PP-StructureV3 |
| 要轉 Markdown / JSON 給 RAG 或 Hermes | PP-OCRv6 只負責文字 | 不夠完整 | PP-StructureV3，或 OCR + 自己排版後處理 |

### 文件型 PDF

文件型 PDF 通常已經有 text layer，可以選取、複製文字。這種 PDF 如果直接整份 OCR，常見問題是：

| 問題 | 原因 |
| --- | --- |
| 速度浪費 | 明明可以直接抽文字，卻先渲染成圖片再 OCR |
| 可能引入錯字 | OCR 會把原本正確的 text layer 重新辨識一遍 |
| 結構弱 | PP-OCRv6 主要輸出文字框與辨識結果，不等於段落、標題、表格重建 |
| 語意順序不保證 | 多欄、註腳、頁眉頁腳可能排序混亂 |

建議流程：

```text
PyMuPDF / pdfplumber / pypdf 抽文字層
  -> 檢查文字是否足夠乾淨
  -> 不足的頁面再丟 PP-OCRv6
  -> 需要版面 Markdown 時改用 PP-StructureV3
```

### 圖片型 PDF

圖片型 PDF 本質上是多頁圖片包在 PDF 裡，這正好是 OCR 的主場。PP-OCRv6 的文件方向分類、影像去扭曲、文字行方向分類、文字偵測、文字辨識等模組，適合處理掃描、旋轉、歪斜與拍照文件。

| 需求 | PP-OCRv6 是否足夠 |
| --- | --- |
| 只要純文字 | 大多夠 |
| 要每行座標 | 夠 |
| 要轉 Markdown | 不夠完整 |
| 要保留表格 | 不夠，改 PP-StructureV3 |
| 要保留雙欄閱讀順序 | 不理想，PP-StructureV3 較合理 |
| 要公式、圖表、印章 | 不是主力，PP-StructureV3 / PaddleOCR-VL 較合理 |

### 實務選型

| 目標 | 推薦 |
| --- | --- |
| 掃描 PDF -> 純文字 | PP-OCRv6 |
| 掃描 PDF -> Markdown | PP-StructureV3 |
| 可選字 PDF -> 純文字 | 先用 PDF text extractor |
| 可選字 PDF -> 結構化 Markdown | 先抽 text layer + layout；不穩再 PP-StructureV3 |
| 混合 PDF：有些頁可選字、有些頁掃描 | text extraction + OCR fallback |
| 表格很多 | PP-StructureV3，不要只用 PP-OCRv6 |
| 公式、圖表、印章很多 | PP-StructureV3 或 PaddleOCR-VL |

注意：PaddleOCR serving API 對 PDF 或多頁 TIFF 預設只處理前 10 頁；如果要取消限制，需要在 pipeline config 裡設定 `max_num_input_imgs: null`。批量 PDF 很容易在這裡踩雷。

## 7. 最懶穩定使用規則

如果目標是「不要每次都判斷 PDF 類型，使用者可以穩定按下去跑」，可以直接把流程收斂成兩條：

```text
圖片 -> PP-OCRv6
PDF  -> PP-StructureV3
```

這不是最快，也不是每種 PDF 的理論最佳解，但最不容易翻車。

| 輸入 / 目標 | 懶人推薦 |
| --- | --- |
| 圖片 OCR | PP-OCRv6 |
| 掃描 PDF | PP-StructureV3；如果只要純文字且追求速度，可用 PP-OCRv6 |
| PDF 不想判斷文件型或圖片型 | PP-StructureV3 |
| 要 Markdown / JSON | PP-StructureV3 |
| 要表格、雙欄、標題層級 | PP-StructureV3 |
| 批量大量圖片、速度優先 | PP-OCRv6 |

可以全部用 PP-StructureV3 嗎？可以，但會比較慢。可以全部用 PP-OCRv6 嗎？不建議，因為複雜 PDF、Markdown、表格與閱讀順序會不穩。

最推薦的懶人平衡是：

```text
圖片走 V6，PDF 預設走 V3。
```

代價是：可選字 PDF 本來可以直接抽 text layer，現在改走 PP-StructureV3 會慢一點；但換來的好處是使用者不用先判斷 PDF 類型，掃描 PDF、複雜版面 PDF、Markdown 輸出都比較穩。

## 8. 35 秒以下處理目標的建議

若目標是把一批圖片壓在 35 秒以下，策略應該是「先用最短 OCR pipeline」，而不是上 VLM。

建議順序：

1. 優先使用 `PP-OCRv6_medium_det` + `PP-OCRv6_medium_rec`，後端先試 `paddle_static`。
2. 若速度不足，改 `small_det` + `small_rec`，再視品質決定是否只把問題圖片回退到 medium。
3. 若圖片來源已經是正向、掃描品質穩定，關閉 `use_doc_orientation_classify` 與 `use_doc_unwarping`。
4. 保留 `use_textline_orientation`，尤其是資料中可能有倒置文字行時。
5. 預先 warm up pipeline，確認模型已下載並在本機 cache。
6. 將 PDF 先控制 DPI，例如 200 DPI，避免不必要的大圖拖慢 det。
7. 只有需要表格 / Markdown / 版面時才跑 PP-StructureV3。
8. 不要用 PaddleOCR-VL 處理大量普通 OCR 圖片，除非需求是文件理解而非純文字抽取。

CLI 範例：

```powershell
paddleocr ocr -i ./images `
  --text_detection_model_name PP-OCRv6_medium_det `
  --text_recognition_model_name PP-OCRv6_medium_rec `
  --use_doc_orientation_classify False `
  --use_doc_unwarping False `
  --use_textline_orientation True `
  --save_path ./output `
  --device gpu:0 `
  --engine paddle_static
```

ONNX Runtime 範例：

```powershell
paddleocr ocr -i ./images `
  --text_detection_model_name PP-OCRv6_medium_det `
  --text_recognition_model_name PP-OCRv6_medium_rec `
  --engine onnxruntime `
  --save_path ./output
```

Transformers / safetensors 範例：

```powershell
paddleocr ocr -i ./images `
  --text_detection_model_name PP-OCRv6_medium_det `
  --text_recognition_model_name PP-OCRv6_medium_rec `
  --engine transformers `
  --save_path ./output
```

## 9. 本專案選型建議

| 任務 | 建議 |
| --- | --- |
| 大量圖片轉 TXT / Markdown-like text | PP-OCRv6 det + rec，輸出 JSON 後由 formatter 轉 Markdown |
| 4200 張圖片批次處理 | 先跑 small 或 medium 的 General OCR，不要先跑 PP-StructureV3 / VLM |
| PDF、表格、章印、版面結構 | PP-StructureV3 |
| 複雜文件理解或欄位抽取 | PP-StructureV3 後接 LLM，或評估 PaddleOCR-VL / PP-ChatOCRv4 |
| Hermes / agent 使用 | 包成本機 OCR service 或 CLI wrapper，輸出 JSON + Markdown |
| 想減少 PaddlePaddle 依賴 | 評估 `onnxruntime` |
| 想用 HF 模型檔 | 評估 `transformers` + safetensors |
| 想用 llama.cpp / GGUF | 不建議用在 PP-OCRv6 det / rec |

最穩的落地路線：

1. 圖片 / PDF page 進 lazy_paddleocr launcher。
2. 一般圖走 PP-OCRv6 det + rec。
3. 只把需要版面的文件送 PP-StructureV3。
4. OCR JSON 統一進 formatter。
5. formatter 輸出 TXT、Markdown 或 JSONL 給 knowledge base / agent。
