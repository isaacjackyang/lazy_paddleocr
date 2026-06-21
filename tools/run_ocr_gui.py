from __future__ import annotations

import os
import queue
import threading
import time
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import run_ocr_launcher as core


ROUTE_AUTO = "auto"
LANG_ZH_TW = "zh_tw"
LANG_EN = "en"

ROUTE_VALUES = (ROUTE_AUTO, core.MODE_OCR, core.MODE_STRUCTURE, core.MODE_BOTH)
OUTPUT_VALUES = (core.OUTPUT_TXT_JSON, core.OUTPUT_TXT_ONLY)
SCAN_VALUES = (core.SCAN_PICTURES_PDF, core.SCAN_PICTURES, core.SCAN_PDF)

TEXT = {
    LANG_ZH_TW: {
        "window_title": "Lazy PaddleOCR GUI",
        "language": "語言",
        "folders": "資料夾",
        "input_folder": "處理資料夾",
        "output_folder": "輸出資料夾",
        "browse": "瀏覽",
        "use_source_output": "輸出到原始文件同位置",
        "include_subfolders": "包含子目錄",
        "mode": "模式",
        "general": "一般模式",
        "expert": "專家模式",
        "file_type": "檔案類型",
        "route": "處理路線",
        "output": "輸出模式",
        "models": "模型",
        "ocr_engine": "OCR 後端",
        "detection_model": "偵測模型",
        "recognition_model": "辨識模型",
        "expert_settings": "專家設定",
        "device": "裝置",
        "gpu_id": "GPU 編號",
        "pdf_dpi": "PDF DPI",
        "keep_pdf_images": "保留 PDF 頁面圖片",
        "final_score": "最終信心門檻",
        "det_limit_side": "偵測邊長上限",
        "det_thresh": "偵測門檻",
        "box_thresh": "文字框門檻",
        "unclip_ratio": "文字框外擴比例",
        "rec_score": "辨識分數門檻",
        "layout_threshold": "版面門檻",
        "structure_coordinates": "輸出版面座標",
        "progress": "處理進度",
        "start": "開始",
        "pause": "暫停",
        "resume": "繼續",
        "stop": "停止",
        "ready": "就緒",
        "starting": "準備開始",
        "invalid_setting": "設定不正確",
        "input_missing": "處理資料夾不存在。",
        "output_missing": "請選擇輸出資料夾，或啟用輸出到原始文件同位置。",
        "resumed": "已繼續。",
        "paused": "已暫停；目前檔案或頁面處理完後會停住。",
        "stop_requested": "已要求停止；等待目前模型推論結束。",
        "preparing_runtime": "準備 Paddle 執行環境。",
        "found_sources": "找到 %d 個來源檔案。",
        "no_pending": "沒有找到待處理的圖片或 PDF。",
        "initializing": "初始化 %s。",
        "runtime": "%s 執行裝置：%s",
        "processing": "正在處理 %s [%s]",
        "completed": "已完成 %d/%d",
        "stopped": "已停止於 %d/%d",
        "done": "完成：%d/%d",
        "failed": "失敗",
        "fatal_error": "嚴重錯誤：%s: %s",
        "gpu_id_integer": "GPU 編號必須是整數。",
        "gpu_id_range": "GPU 編號必須大於或等於 0。",
        "must_integer": "%s 必須是整數。",
        "must_positive": "%s 必須大於 0。",
        "must_number": "%s 必須是數字。",
        "lang_zh_tw": "繁體中文",
        "lang_en": "English",
    },
    LANG_EN: {
        "window_title": "Lazy PaddleOCR GUI",
        "language": "Language",
        "folders": "Folders",
        "input_folder": "Input folder",
        "output_folder": "Output folder",
        "browse": "Browse",
        "use_source_output": "Use source folder as output",
        "include_subfolders": "Include subfolders",
        "mode": "Mode",
        "general": "General",
        "expert": "Expert",
        "file_type": "File type",
        "route": "Route",
        "output": "Output",
        "models": "Models",
        "ocr_engine": "OCR engine",
        "detection_model": "Detection model",
        "recognition_model": "Recognition model",
        "expert_settings": "Expert settings",
        "device": "Device",
        "gpu_id": "GPU id",
        "pdf_dpi": "PDF DPI",
        "keep_pdf_images": "Keep rendered PDF images",
        "final_score": "Final score",
        "det_limit_side": "Det limit side",
        "det_thresh": "Det thresh",
        "box_thresh": "Box thresh",
        "unclip_ratio": "Unclip ratio",
        "rec_score": "Rec score",
        "layout_threshold": "Layout threshold",
        "structure_coordinates": "Structure coordinates",
        "progress": "Progress",
        "start": "Start",
        "pause": "Pause",
        "resume": "Resume",
        "stop": "Stop",
        "ready": "Ready",
        "starting": "Starting",
        "invalid_setting": "Invalid setting",
        "input_missing": "Input folder does not exist.",
        "output_missing": "Choose an output folder or enable source-folder output.",
        "resumed": "Resumed.",
        "paused": "Paused after the current file/page finishes.",
        "stop_requested": "Stop requested. Waiting for the current model call to finish.",
        "preparing_runtime": "Preparing Paddle runtime.",
        "found_sources": "Found %d source file(s).",
        "no_pending": "No pending image/PDF files found.",
        "initializing": "Initializing %s.",
        "runtime": "%s runtime: %s",
        "processing": "Processing %s [%s]",
        "completed": "Completed %d/%d",
        "stopped": "Stopped at %d/%d",
        "done": "Done: %d/%d",
        "failed": "Failed",
        "fatal_error": "Fatal error: %s: %s",
        "gpu_id_integer": "GPU id must be an integer.",
        "gpu_id_range": "GPU id must be zero or greater.",
        "must_integer": "%s must be an integer.",
        "must_positive": "%s must be greater than zero.",
        "must_number": "%s must be a number.",
        "lang_zh_tw": "繁體中文",
        "lang_en": "English",
    },
}

CHOICE_TEXT = {
    "route": {
        ROUTE_AUTO: {
            LANG_ZH_TW: "自動：圖片 V6，PDF V3 Markdown",
            LANG_EN: "Auto: images V6, PDFs V3 Markdown",
        },
        core.MODE_OCR: {LANG_ZH_TW: "只用 PP-OCRv6", LANG_EN: "PP-OCRv6 only"},
        core.MODE_STRUCTURE: {LANG_ZH_TW: "只用 PP-StructureV3", LANG_EN: "PP-StructureV3 only"},
        core.MODE_BOTH: {LANG_ZH_TW: "兩種都執行", LANG_EN: "Run both"},
    },
    "output": {
        core.OUTPUT_TXT_JSON: {
            LANG_ZH_TW: "文字 / Markdown + JSON",
            LANG_EN: "Text / Markdown + JSON",
        },
        core.OUTPUT_TXT_ONLY: {
            LANG_ZH_TW: "只輸出文字 / Markdown",
            LANG_EN: "Text / Markdown only",
        },
    },
    "scan": {
        core.SCAN_PICTURES_PDF: {LANG_ZH_TW: "圖片與 PDF", LANG_EN: "Images and PDFs"},
        core.SCAN_PICTURES: {LANG_ZH_TW: "只處理圖片", LANG_EN: "Images only"},
        core.SCAN_PDF: {LANG_ZH_TW: "只處理 PDF", LANG_EN: "PDFs only"},
    },
    "language": {
        LANG_ZH_TW: {LANG_ZH_TW: "繁體中文", LANG_EN: "繁體中文"},
        LANG_EN: {LANG_ZH_TW: "English", LANG_EN: "English"},
    },
}


@dataclass
class GuiConfig:
    input_dir: Path
    output_dir: Path | None
    recursive: bool
    interface_mode: str
    scan_target: str
    route_mode: str
    output_mode: str
    device_preference: str
    gpu_id: int | None
    engine: str
    text_detection_model: str
    text_recognition_model: str
    pdf_dpi: int
    keep_pdf_images: bool
    score_thresh: float
    text_det_limit_side_len: int | None
    text_det_thresh: float | None
    text_det_box_thresh: float | None
    text_det_unclip_ratio: float | None
    text_rec_score_thresh: float | None
    layout_threshold: float | None
    structure_coordinate_mode: bool


class PaddleOcrGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.language_code = LANG_ZH_TW
        self.title(self._t("window_title"))
        self.geometry("980x760")
        self.minsize(860, 650)

        self.log_queue: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.worker_thread: threading.Thread | None = None
        self.pause_event = threading.Event()
        self.stop_event = threading.Event()

        self.input_dir_var = tk.StringVar(value=str(Path.cwd()))
        self.output_dir_var = tk.StringVar(value="")
        self.use_source_output_var = tk.BooleanVar(value=True)
        self.recursive_var = tk.BooleanVar(value=False)
        self.language_var = tk.StringVar(value=self._choice_label("language", LANG_ZH_TW))
        self.interface_mode_var = tk.StringVar(value=core.UI_MODE_GENERAL)
        self.scan_target_var = tk.StringVar(value=self._choice_label("scan", core.SCAN_PICTURES_PDF))
        self.route_mode_var = tk.StringVar(value=self._choice_label("route", ROUTE_AUTO))
        self.output_mode_var = tk.StringVar(value=self._choice_label("output", core.OUTPUT_TXT_JSON))

        self.engine_var = tk.StringVar(value=core.DEFAULT_OCR_ENGINE)
        self.det_model_var = tk.StringVar(value=core.DEFAULT_TEXT_DETECTION_MODEL)
        self.rec_model_var = tk.StringVar(value=core.DEFAULT_TEXT_RECOGNITION_MODEL)

        self.device_var = tk.StringVar(value=core.DEVICE_AUTO)
        self.gpu_id_var = tk.StringVar(value="")
        self.pdf_dpi_var = tk.StringVar(value="200")
        self.keep_pdf_images_var = tk.BooleanVar(value=False)
        self.score_thresh_var = tk.StringVar(value="0.70")
        self.text_det_limit_var = tk.StringVar(value="")
        self.text_det_thresh_var = tk.StringVar(value="")
        self.text_det_box_thresh_var = tk.StringVar(value="")
        self.text_det_unclip_var = tk.StringVar(value="")
        self.text_rec_score_var = tk.StringVar(value="")
        self.layout_threshold_var = tk.StringVar(value="")
        self.structure_coordinate_var = tk.BooleanVar(value=False)

        self.progress_var = tk.DoubleVar(value=0)
        self.progress_label_var = tk.StringVar(value=self._t("ready"))
        self.pause_button_text = tk.StringVar(value=self._t("pause"))

        self._build_ui()
        self._refresh_mode_visibility()
        self._refresh_output_state()
        self.after(120, self._drain_log_queue)

    def _t(self, key: str) -> str:
        return TEXT[self.language_code][key]

    def _choice_label(self, group: str, value: str) -> str:
        return CHOICE_TEXT[group][value][self.language_code]

    def _choice_labels(self, group: str, values: tuple[str, ...]) -> list[str]:
        return [self._choice_label(group, value) for value in values]

    def _choice_value(self, group: str, label: str) -> str:
        for value, labels in CHOICE_TEXT[group].items():
            if label in labels.values():
                return value
        raise ValueError("Unknown choice label: %s" % label)

    def _set_choice_var(self, variable: tk.StringVar, group: str, value: str) -> None:
        variable.set(self._choice_label(group, value))

    def _build_ui(self) -> None:
        for child in self.winfo_children():
            child.destroy()
        self.title(self._t("window_title"))

        root = ttk.Frame(self, padding=14)
        root.pack(fill=tk.BOTH, expand=True)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(5, weight=1)

        top = ttk.Frame(root)
        top.grid(row=0, column=0, sticky="ew")
        top.columnconfigure(0, weight=1)
        self._add_combo(
            top,
            0,
            1,
            self._t("language"),
            self.language_var,
            self._choice_labels("language", (LANG_ZH_TW, LANG_EN)),
        ).bind("<<ComboboxSelected>>", self._on_language_change)

        paths = ttk.LabelFrame(root, text=self._t("folders"), padding=10)
        paths.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        paths.columnconfigure(1, weight=1)

        ttk.Label(paths, text=self._t("input_folder")).grid(row=0, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(paths, textvariable=self.input_dir_var).grid(row=0, column=1, sticky="ew", pady=3)
        ttk.Button(paths, text=self._t("browse"), command=self._browse_input).grid(row=0, column=2, padx=(8, 0), pady=3)

        ttk.Label(paths, text=self._t("output_folder")).grid(row=1, column=0, sticky="w", padx=(0, 8), pady=3)
        self.output_entry = ttk.Entry(paths, textvariable=self.output_dir_var)
        self.output_entry.grid(row=1, column=1, sticky="ew", pady=3)
        self.output_browse_button = ttk.Button(paths, text=self._t("browse"), command=self._browse_output)
        self.output_browse_button.grid(row=1, column=2, padx=(8, 0), pady=3)

        ttk.Checkbutton(
            paths,
            text=self._t("use_source_output"),
            variable=self.use_source_output_var,
            command=self._refresh_output_state,
        ).grid(row=2, column=1, sticky="w", pady=(4, 0))
        ttk.Checkbutton(paths, text=self._t("include_subfolders"), variable=self.recursive_var).grid(
            row=2, column=2, sticky="w", padx=(8, 0), pady=(4, 0)
        )

        basic = ttk.LabelFrame(root, text=self._t("mode"), padding=10)
        basic.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        for col in range(4):
            basic.columnconfigure(col, weight=1)

        mode_row = ttk.Frame(basic)
        mode_row.grid(row=0, column=0, columnspan=4, sticky="ew")
        ttk.Radiobutton(
            mode_row,
            text=self._t("general"),
            value=core.UI_MODE_GENERAL,
            variable=self.interface_mode_var,
            command=self._refresh_mode_visibility,
        ).pack(side=tk.LEFT)
        ttk.Radiobutton(
            mode_row,
            text=self._t("expert"),
            value=core.UI_MODE_EXPERT,
            variable=self.interface_mode_var,
            command=self._refresh_mode_visibility,
        ).pack(side=tk.LEFT, padx=(20, 0))

        self._add_combo(basic, 1, 0, self._t("file_type"), self.scan_target_var, self._choice_labels("scan", SCAN_VALUES))
        self._add_combo(basic, 1, 1, self._t("route"), self.route_mode_var, self._choice_labels("route", ROUTE_VALUES))
        self._add_combo(basic, 1, 2, self._t("output"), self.output_mode_var, self._choice_labels("output", OUTPUT_VALUES))

        models = ttk.LabelFrame(root, text=self._t("models"), padding=10)
        models.grid(row=3, column=0, sticky="ew", pady=(10, 0))
        for col in range(3):
            models.columnconfigure(col, weight=1)

        self._add_combo(
            models,
            0,
            0,
            self._t("ocr_engine"),
            self.engine_var,
            ["paddle_static", "onnxruntime", "paddle", "transformers"],
        )
        self._add_combo(
            models,
            0,
            1,
            self._t("detection_model"),
            self.det_model_var,
            ["PP-OCRv6_medium_det", "PP-OCRv6_small_det", "PP-OCRv6_tiny_det"],
        )
        self._add_combo(
            models,
            0,
            2,
            self._t("recognition_model"),
            self.rec_model_var,
            ["PP-OCRv6_medium_rec", "PP-OCRv6_small_rec", "PP-OCRv6_tiny_rec"],
        )

        self.expert_frame = ttk.LabelFrame(root, text=self._t("expert_settings"), padding=10)
        self.expert_frame.grid(row=4, column=0, sticky="ew", pady=(10, 0))
        for col in range(4):
            self.expert_frame.columnconfigure(col, weight=1)

        self._add_combo(self.expert_frame, 0, 0, self._t("device"), self.device_var, list(core.DEVICE_CHOICES))
        self._add_entry(self.expert_frame, 0, 1, self._t("gpu_id"), self.gpu_id_var)
        self._add_entry(self.expert_frame, 0, 2, self._t("pdf_dpi"), self.pdf_dpi_var)
        ttk.Checkbutton(
            self.expert_frame,
            text=self._t("keep_pdf_images"),
            variable=self.keep_pdf_images_var,
        ).grid(row=0, column=3, sticky="w", padx=8, pady=(18, 0))

        self._add_entry(self.expert_frame, 1, 0, self._t("final_score"), self.score_thresh_var)
        self._add_entry(self.expert_frame, 1, 1, self._t("det_limit_side"), self.text_det_limit_var)
        self._add_entry(self.expert_frame, 1, 2, self._t("det_thresh"), self.text_det_thresh_var)
        self._add_entry(self.expert_frame, 1, 3, self._t("box_thresh"), self.text_det_box_thresh_var)

        self._add_entry(self.expert_frame, 2, 0, self._t("unclip_ratio"), self.text_det_unclip_var)
        self._add_entry(self.expert_frame, 2, 1, self._t("rec_score"), self.text_rec_score_var)
        self._add_entry(self.expert_frame, 2, 2, self._t("layout_threshold"), self.layout_threshold_var)
        ttk.Checkbutton(
            self.expert_frame,
            text=self._t("structure_coordinates"),
            variable=self.structure_coordinate_var,
        ).grid(row=2, column=3, sticky="w", padx=8, pady=(18, 0))

        log_frame = ttk.LabelFrame(root, text=self._t("progress"), padding=10)
        log_frame.grid(row=5, column=0, sticky="nsew", pady=(10, 0))
        log_frame.rowconfigure(2, weight=1)
        log_frame.columnconfigure(0, weight=1)

        ttk.Progressbar(log_frame, variable=self.progress_var, maximum=100).grid(row=0, column=0, sticky="ew")
        ttk.Label(log_frame, textvariable=self.progress_label_var).grid(row=1, column=0, sticky="w", pady=(6, 8))

        self.log_text = tk.Text(log_frame, height=16, wrap=tk.WORD, state=tk.DISABLED)
        self.log_text.grid(row=2, column=0, sticky="nsew")
        log_scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        log_scroll.grid(row=2, column=1, sticky="ns")
        self.log_text.configure(yscrollcommand=log_scroll.set)

        buttons = ttk.Frame(root)
        buttons.grid(row=6, column=0, sticky="ew", pady=(12, 0))
        buttons.columnconfigure(0, weight=1)
        self.start_button = ttk.Button(buttons, text=self._t("start"), command=self._start)
        self.start_button.pack(side=tk.LEFT)
        self.pause_button = ttk.Button(buttons, textvariable=self.pause_button_text, command=self._toggle_pause, state=tk.DISABLED)
        self.pause_button.pack(side=tk.LEFT, padx=(8, 0))
        self.stop_button = ttk.Button(buttons, text=self._t("stop"), command=self._stop, state=tk.DISABLED)
        self.stop_button.pack(side=tk.LEFT, padx=(8, 0))

    def _add_combo(
        self,
        parent: ttk.Frame,
        row: int,
        column: int,
        label: str,
        variable: tk.StringVar,
        values: list[str],
    ) -> ttk.Combobox:
        frame = ttk.Frame(parent)
        frame.grid(row=row, column=column, sticky="ew", padx=6, pady=4)
        frame.columnconfigure(0, weight=1)
        ttk.Label(frame, text=label).grid(row=0, column=0, sticky="w")
        combo = ttk.Combobox(frame, textvariable=variable, values=values, state="readonly")
        combo.grid(row=1, column=0, sticky="ew")
        return combo

    def _add_entry(
        self,
        parent: ttk.Frame,
        row: int,
        column: int,
        label: str,
        variable: tk.StringVar,
    ) -> ttk.Entry:
        frame = ttk.Frame(parent)
        frame.grid(row=row, column=column, sticky="ew", padx=6, pady=4)
        frame.columnconfigure(0, weight=1)
        ttk.Label(frame, text=label).grid(row=0, column=0, sticky="w")
        entry = ttk.Entry(frame, textvariable=variable)
        entry.grid(row=1, column=0, sticky="ew")
        return entry

    def _browse_input(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.input_dir_var.get() or str(Path.cwd()))
        if selected:
            self.input_dir_var.set(selected)

    def _browse_output(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output_dir_var.get() or self.input_dir_var.get() or str(Path.cwd()))
        if selected:
            self.output_dir_var.set(selected)

    def _refresh_output_state(self) -> None:
        state = tk.DISABLED if self.use_source_output_var.get() else tk.NORMAL
        self.output_entry.configure(state=state)
        self.output_browse_button.configure(state=state)

    def _on_language_change(self, _event: object | None = None) -> None:
        scan_value = self._choice_value("scan", self.scan_target_var.get())
        route_value = self._choice_value("route", self.route_mode_var.get())
        output_value = self._choice_value("output", self.output_mode_var.get())
        language_value = self._choice_value("language", self.language_var.get())

        self.language_code = language_value
        self._set_choice_var(self.language_var, "language", language_value)
        self._set_choice_var(self.scan_target_var, "scan", scan_value)
        self._set_choice_var(self.route_mode_var, "route", route_value)
        self._set_choice_var(self.output_mode_var, "output", output_value)
        self.progress_label_var.set(self._t("ready"))
        self.pause_button_text.set(self._t("resume") if self.pause_event.is_set() else self._t("pause"))

        self._build_ui()
        self._refresh_mode_visibility()
        self._refresh_output_state()

    def _refresh_mode_visibility(self) -> None:
        is_expert = self.interface_mode_var.get() == core.UI_MODE_EXPERT
        if is_expert:
            self.expert_frame.grid()
        else:
            self.expert_frame.grid_remove()
            self._set_choice_var(self.route_mode_var, "route", ROUTE_AUTO)

    def _start(self) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            return
        try:
            config = self._read_config()
        except ValueError as exc:
            messagebox.showerror(self._t("invalid_setting"), str(exc))
            return

        self.pause_event.clear()
        self.stop_event.clear()
        self.progress_var.set(0)
        self.progress_label_var.set(self._t("starting"))
        self._clear_log()
        self._set_running(True)

        self.worker_thread = threading.Thread(target=self._worker, args=(config,), daemon=True)
        self.worker_thread.start()

    def _toggle_pause(self) -> None:
        if not (self.worker_thread and self.worker_thread.is_alive()):
            return
        if self.pause_event.is_set():
            self.pause_event.clear()
            self.pause_button_text.set(self._t("pause"))
            self._log(self._t("resumed"))
        else:
            self.pause_event.set()
            self.pause_button_text.set(self._t("resume"))
            self._log(self._t("paused"))

    def _stop(self) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            self.stop_event.set()
            self.pause_event.clear()
            self.pause_button_text.set(self._t("pause"))
            self._log(self._t("stop_requested"))

    def _set_running(self, running: bool) -> None:
        self.start_button.configure(state=tk.DISABLED if running else tk.NORMAL)
        self.pause_button.configure(state=tk.NORMAL if running else tk.DISABLED)
        self.stop_button.configure(state=tk.NORMAL if running else tk.DISABLED)
        if not running:
            self.pause_button_text.set(self._t("pause"))

    def _read_config(self) -> GuiConfig:
        input_dir = Path(self.input_dir_var.get()).expanduser()
        if not input_dir.exists() or not input_dir.is_dir():
            raise ValueError(self._t("input_missing"))

        output_dir = None
        if not self.use_source_output_var.get():
            raw_output = self.output_dir_var.get().strip()
            if not raw_output:
                raise ValueError(self._t("output_missing"))
            output_dir = Path(raw_output).expanduser()

        interface_mode = self.interface_mode_var.get()
        is_expert = interface_mode == core.UI_MODE_EXPERT

        return GuiConfig(
            input_dir=input_dir,
            output_dir=output_dir,
            recursive=self.recursive_var.get(),
            interface_mode=interface_mode,
            scan_target=self._choice_value("scan", self.scan_target_var.get()),
            route_mode=self._choice_value("route", self.route_mode_var.get()),
            output_mode=self._choice_value("output", self.output_mode_var.get()),
            device_preference=self.device_var.get() if is_expert else core.DEVICE_AUTO,
            gpu_id=self._parse_optional_gpu_id(self.gpu_id_var.get()) if is_expert else None,
            engine=self.engine_var.get().strip() or core.DEFAULT_OCR_ENGINE,
            text_detection_model=self.det_model_var.get().strip() or core.DEFAULT_TEXT_DETECTION_MODEL,
            text_recognition_model=self.rec_model_var.get().strip() or core.DEFAULT_TEXT_RECOGNITION_MODEL,
            pdf_dpi=self._parse_int(self.pdf_dpi_var.get(), "PDF DPI") if is_expert else 200,
            keep_pdf_images=self.keep_pdf_images_var.get() if is_expert else False,
            score_thresh=self._parse_float(self.score_thresh_var.get(), "Final score") if is_expert else 0.70,
            text_det_limit_side_len=self._parse_optional_int(self.text_det_limit_var.get(), "Det limit side") if is_expert else None,
            text_det_thresh=self._parse_optional_float(self.text_det_thresh_var.get(), "Det thresh") if is_expert else None,
            text_det_box_thresh=self._parse_optional_float(self.text_det_box_thresh_var.get(), "Box thresh") if is_expert else None,
            text_det_unclip_ratio=self._parse_optional_float(self.text_det_unclip_var.get(), "Unclip ratio") if is_expert else None,
            text_rec_score_thresh=self._parse_optional_float(self.text_rec_score_var.get(), "Rec score") if is_expert else None,
            layout_threshold=self._parse_optional_float(self.layout_threshold_var.get(), "Layout threshold") if is_expert else None,
            structure_coordinate_mode=self.structure_coordinate_var.get() if is_expert else False,
        )

    def _worker(self, config: GuiConfig) -> None:
        completed = 0
        total = 0
        try:
            self._post_log(self._t("preparing_runtime"))
            self._configure_models(config)
            core.configure_frozen_runtime_paths()
            core.import_bundled_model_cache()
            core.patch_frozen_paddlex_extra_checks()

            image_exts, pdf_exts = core.select_scan_exts(
                config.scan_target,
                set(core.DEFAULT_IMAGE_EXTS),
                set(core.DEFAULT_PDF_EXTS),
            )
            targets = core.resolve_pending_targets(config.input_dir, config.recursive, image_exts, pdf_exts)
            image_targets = [path for path in targets if path.suffix.lower() in image_exts]
            pdf_targets = [path for path in targets if path.suffix.lower() in pdf_exts]
            jobs = self._build_jobs(config, targets, image_targets, pdf_targets, image_exts, pdf_exts)
            total = sum(len(job["targets"]) for job in jobs)

            self._post_progress(completed, total, self._t("found_sources") % len(targets))
            if total == 0:
                self._post_log(self._t("no_pending"))
                return

            tuning = core.make_pipeline_tuning_settings(
                text_det_limit_side_len=config.text_det_limit_side_len,
                text_det_thresh=config.text_det_thresh,
                text_det_box_thresh=config.text_det_box_thresh,
                text_det_unclip_ratio=config.text_det_unclip_ratio,
                text_rec_score_thresh=config.text_rec_score_thresh,
                layout_threshold=config.layout_threshold,
            )

            for job in jobs:
                if self.stop_event.is_set():
                    break
                mode = job["mode"]
                self._post_log(self._t("initializing") % mode)
                runtime_state = core.create_mode_pipeline(
                    mode,
                    config.device_preference,
                    tuning,
                    config.gpu_id,
                )
                self._post_log(self._t("runtime") % (mode, runtime_state["runtime_device"]))

                for src in job["targets"]:
                    if self.stop_event.is_set():
                        break
                    self._wait_while_paused()
                    rel = self._display_rel(src, config.input_dir)
                    self._post_progress(completed, total, self._t("processing") % (rel, mode))
                    self._post_log("PROCESS [%s] %s" % (mode, rel))
                    try:
                        out_text, out_json = self._process_one(
                            config=config,
                            mode=mode,
                            runtime_state=runtime_state,
                            src=src,
                            input_root=config.input_dir,
                            output_root=config.output_dir,
                            image_exts=job["image_exts"],
                            pdf_exts=job["pdf_exts"],
                            tuning_settings=tuning,
                        )
                        self._post_log("  TEXT -> %s" % out_text)
                        if out_json:
                            self._post_log("  JSON -> %s" % out_json)
                    except Exception as exc:
                        self._post_log("  FAIL -> %s: %s" % (type(exc).__name__, exc))
                        self._post_log(traceback.format_exc().strip())
                    completed += 1
                    self._post_progress(completed, total, self._t("completed") % (completed, total))

            if self.stop_event.is_set():
                self._post_progress(completed, total, self._t("stopped") % (completed, total))
            else:
                self._post_progress(completed, total, self._t("done") % (completed, total))
        except Exception as exc:
            self._post_log(self._t("fatal_error") % (type(exc).__name__, exc))
            self._post_log(traceback.format_exc().strip())
            self._post_progress(completed, total, self._t("failed"))
        finally:
            self.log_queue.put(("done", None))

    def _build_jobs(
        self,
        config: GuiConfig,
        targets: list[Path],
        image_targets: list[Path],
        pdf_targets: list[Path],
        image_exts: set[str],
        pdf_exts: set[str],
    ) -> list[dict[str, Any]]:
        route = config.route_mode
        if config.interface_mode == core.UI_MODE_GENERAL or route == ROUTE_AUTO:
            jobs = []
            if image_targets:
                jobs.append(
                    {
                        "mode": core.MODE_OCR,
                        "targets": image_targets,
                        "image_exts": image_exts,
                        "pdf_exts": set(),
                    }
                )
            if pdf_targets:
                jobs.append(
                    {
                        "mode": core.MODE_STRUCTURE,
                        "targets": pdf_targets,
                        "image_exts": set(),
                        "pdf_exts": pdf_exts,
                    }
                )
            return jobs

        jobs = []
        if route in {core.MODE_OCR, core.MODE_BOTH}:
            jobs.append({"mode": core.MODE_OCR, "targets": targets, "image_exts": image_exts, "pdf_exts": pdf_exts})
        if route in {core.MODE_STRUCTURE, core.MODE_BOTH}:
            jobs.append({"mode": core.MODE_STRUCTURE, "targets": targets, "image_exts": image_exts, "pdf_exts": pdf_exts})
        return jobs

    def _process_one(
        self,
        *,
        config: GuiConfig,
        mode: str,
        runtime_state: dict[str, Any],
        src: Path,
        input_root: Path,
        output_root: Path | None,
        image_exts: set[str],
        pdf_exts: set[str],
        tuning_settings: dict[str, Any],
    ) -> tuple[Path, Path | None]:
        per_page_results: list[dict[str, Any]] = []
        suffix = src.suffix.lower()

        if suffix in image_exts:
            self._append_prediction_results(
                mode,
                runtime_state,
                core.predict_with_runtime_retry(mode, runtime_state, str(src)),
                per_page_results,
                config.score_thresh,
                config.structure_coordinate_mode,
            )
        elif suffix in pdf_exts:
            if mode == core.MODE_STRUCTURE:
                self._append_prediction_results(
                    mode,
                    runtime_state,
                    core.predict_with_runtime_retry(mode, runtime_state, str(src)),
                    per_page_results,
                    config.score_thresh,
                    config.structure_coordinate_mode,
                )
            else:
                for page_index, png_bytes, saved_img_path in core.render_pdf_pages(
                    src,
                    dpi=config.pdf_dpi,
                    keep_images=config.keep_pdf_images,
                    pdf_image_dirname="_pdf_pages",
                ):
                    if self.stop_event.is_set():
                        break
                    self._wait_while_paused()
                    results = core.predict_with_runtime_retry(mode, runtime_state, png_bytes)
                    for res in results:
                        payload = core.normalize_json_attr(getattr(res, "json", None))
                        payload = core.filter_ocr_payload(payload, config.score_thresh)
                        payload["page_index"] = page_index
                        payload["rendered_page_image"] = saved_img_path
                        per_page_results.append(payload)
        else:
            raise ValueError("Unsupported source extension: %s" % src.suffix)

        text_output = core.results_to_text(
            mode,
            per_page_results,
            structure_coordinate_mode=config.structure_coordinate_mode,
        )
        result_payload = {
            "source_file": str(src),
            "mode": mode,
            "text_score_thresh": config.score_thresh,
            "structure_coordinate_mode": config.structure_coordinate_mode,
            "pdf_render_dpi": config.pdf_dpi,
            "keep_pdf_images": config.keep_pdf_images,
            "pipeline_tuning": core.summarize_pipeline_tuning(mode, tuning_settings),
            "results": per_page_results,
        }

        out_text, out_json = self._output_paths(src, input_root, output_root, mode)
        core.safe_write_text(out_text, text_output)
        if core.writes_json_output(config.output_mode):
            core.safe_write_json(out_json, result_payload)
            return out_text, out_json
        core.safe_unlink(out_json)
        return out_text, None

    def _append_prediction_results(
        self,
        mode: str,
        runtime_state: dict[str, Any],
        results: Any,
        per_page_results: list[dict[str, Any]],
        score_thresh: float,
        structure_coordinate_mode: bool,
    ) -> None:
        for res in results:
            payload = core.normalize_json_attr(getattr(res, "json", None))
            if mode == core.MODE_OCR:
                payload = core.filter_ocr_payload(payload, score_thresh)
            else:
                payload["_extracted_texts"] = core.extract_structure_texts(res, payload, score_thresh)
                if structure_coordinate_mode:
                    payload["_coordinate_entries"] = core.extract_structure_coordinate_entries(payload, score_thresh)
            per_page_results.append(payload)

    def _output_paths(
        self,
        src: Path,
        input_root: Path,
        output_root: Path | None,
        mode: str,
    ) -> tuple[Path, Path]:
        if output_root is None:
            return core.output_paths(src, input_root, mode)

        try:
            rel_parent = src.parent.relative_to(input_root)
        except ValueError:
            rel_parent = Path()
        target_dir = output_root / rel_parent
        text_ext = ".md" if mode == core.MODE_STRUCTURE else ".txt"
        return target_dir / f"{src.stem}.{mode}{text_ext}", target_dir / f"{src.stem}.{mode}.json"

    def _configure_models(self, config: GuiConfig) -> None:
        os.environ["PADDLE_OCR_ENGINE"] = config.engine
        os.environ["PADDLE_TEXT_DETECTION_MODEL"] = config.text_detection_model
        os.environ["PADDLE_TEXT_RECOGNITION_MODEL"] = config.text_recognition_model
        core.DEFAULT_OCR_ENGINE = config.engine
        core.DEFAULT_TEXT_DETECTION_MODEL = config.text_detection_model
        core.DEFAULT_TEXT_RECOGNITION_MODEL = config.text_recognition_model

    def _wait_while_paused(self) -> None:
        while self.pause_event.is_set() and not self.stop_event.is_set():
            time.sleep(0.15)

    def _post_log(self, text: str) -> None:
        self.log_queue.put(("log", text))

    def _post_progress(self, completed: int, total: int, label: str) -> None:
        percent = 0 if total <= 0 else int((completed / total) * 100)
        self.log_queue.put(("progress", (percent, label)))

    def _drain_log_queue(self) -> None:
        try:
            while True:
                kind, payload = self.log_queue.get_nowait()
                if kind == "log":
                    self._log(payload)
                elif kind == "progress":
                    percent, label = payload
                    self.progress_var.set(percent)
                    self.progress_label_var.set(label)
                elif kind == "done":
                    self._set_running(False)
        except queue.Empty:
            pass
        self.after(120, self._drain_log_queue)

    def _log(self, text: str) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _clear_log(self) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _display_rel(self, path: Path, root: Path) -> str:
        try:
            return str(path.relative_to(root))
        except ValueError:
            return str(path)

    def _parse_int(self, value: str, label: str) -> int:
        try:
            parsed = int(value.strip())
        except ValueError as exc:
            raise ValueError(self._t("must_integer") % label) from exc
        if parsed <= 0:
            raise ValueError(self._t("must_positive") % label)
        return parsed

    def _parse_optional_int(self, value: str, label: str) -> int | None:
        if not value.strip():
            return None
        return self._parse_int(value, label)

    def _parse_optional_gpu_id(self, value: str) -> int | None:
        if not value.strip():
            return None
        try:
            parsed = int(value.strip())
        except ValueError as exc:
            raise ValueError(self._t("gpu_id_integer")) from exc
        if parsed < 0:
            raise ValueError(self._t("gpu_id_range"))
        return parsed

    def _parse_float(self, value: str, label: str) -> float:
        try:
            return float(value.strip())
        except ValueError as exc:
            raise ValueError(self._t("must_number") % label) from exc

    def _parse_optional_float(self, value: str, label: str) -> float | None:
        if not value.strip():
            return None
        return self._parse_float(value, label)


def main() -> int:
    app = PaddleOcrGui()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
