from __future__ import annotations

import argparse
import html
import importlib
import importlib.util
import inspect
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Iterable

os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

import fitz  # PyMuPDF


DEFAULT_IMAGE_EXTS = [".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp"]
DEFAULT_PDF_EXTS = [".pdf"]
PROMPT_PICTURE_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

MODE_OCR = "ppocrv5"
MODE_STRUCTURE = "ppstructurev3"
OUTPUT_TXT_ONLY = "txt_only"
OUTPUT_TXT_JSON = "txt_json"
TEXT_LAYOUT_PER_FILE = "per_file"
TEXT_LAYOUT_KNOWLEDGEBASE = "knowledgebase"
SCAN_PICTURES = "pictures"
SCAN_PDF = "pdf"
SCAN_PICTURES_PDF = "pictures_pdf"
DEVICE_AUTO = "auto"
DEVICE_CPU = "cpu"
DEVICE_GPU = "gpu"
DEVICE_CHOICES = (DEVICE_AUTO, DEVICE_CPU, DEVICE_GPU)

EXCLUDED_DIR_NAMES = {
    ".venv",
    "venv",
    "__pycache__",
    ".git",
    "_pdf_pages",
    "node_modules",
}


def get_app_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def iter_resource_roots() -> Iterable[Path]:
    seen: set[Path] = set()
    for raw_root in (get_app_root(), getattr(sys, "_MEIPASS", None)):
        if not raw_root:
            continue
        root = Path(raw_root).resolve()
        if root in seen:
            continue
        seen.add(root)
        yield root


def import_bundled_model_cache() -> None:
    source_root = None
    for base in iter_resource_roots():
        candidate = base / "bundled_model_cache" / "official_models"
        if candidate.is_dir():
            source_root = candidate
            break

    if source_root is None:
        return

    target_root = Path.home() / ".paddlex" / "official_models"
    copied_any = False
    target_root.mkdir(parents=True, exist_ok=True)

    for item in sorted(source_root.iterdir()):
        destination = target_root / item.name
        if destination.exists():
            continue
        if item.is_dir():
            shutil.copytree(item, destination)
        else:
            shutil.copy2(item, destination)
        copied_any = True

    if copied_any:
        print(f"[MODEL CACHE] Imported bundled models to {target_root}")


def configure_frozen_runtime_paths() -> None:
    if not getattr(sys, "frozen", False):
        return

    candidate_dirs: list[Path] = []
    runtime_rel_paths = [
        Path("paddle") / "libs",
        Path("nvidia") / "cublas" / "bin",
        Path("nvidia") / "cuda_nvrtc" / "bin",
        Path("nvidia") / "cuda_runtime" / "bin",
        Path("nvidia") / "cudnn" / "bin",
        Path("nvidia") / "cufft" / "bin",
        Path("nvidia") / "curand" / "bin",
        Path("nvidia") / "cusolver" / "bin",
        Path("nvidia") / "cusparse" / "bin",
    ]

    for base in iter_resource_roots():
        for rel_path in runtime_rel_paths:
            candidate = (base / rel_path).resolve()
            if candidate.is_dir() and candidate not in candidate_dirs:
                candidate_dirs.append(candidate)

    if not candidate_dirs:
        return

    for dll_dir in candidate_dirs:
        try:
            os.add_dll_directory(str(dll_dir))
        except (AttributeError, FileNotFoundError, OSError):
            pass

    current_path = os.environ.get("PATH", "")
    extra_path = os.pathsep.join(str(path) for path in candidate_dirs)
    os.environ["PATH"] = extra_path if not current_path else extra_path + os.pathsep + current_path


def load_paddle_entrypoints():
    from paddleocr import PPStructureV3, PaddleOCR

    return PaddleOCR, PPStructureV3


def patch_loaded_paddlex_guarded_imports() -> None:
    for module_name, module in list(sys.modules.items()):
        if not module_name.startswith("paddlex."):
            continue

        module_file = getattr(module, "__file__", None)
        if not module_file:
            continue

        try:
            source_lines = Path(module_file).read_text(encoding="utf-8").splitlines()
        except Exception:
            continue

        inside_guard = False
        guard_indent = 0
        for line in source_lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            indent = len(line) - len(line.lstrip())
            if stripped.startswith('if is_dep_available("') and stripped.endswith('"):'):
                inside_guard = True
                guard_indent = indent
                continue

            if inside_guard and indent <= guard_indent:
                inside_guard = False

            if not inside_guard:
                continue

            if stripped.startswith("import "):
                imports = stripped.removeprefix("import ").split(",")
                for item in imports:
                    item = item.strip()
                    if not item:
                        continue
                    if " as " in item:
                        import_name, alias = [part.strip() for part in item.split(" as ", 1)]
                    else:
                        import_name = item
                        alias = item.split(".", 1)[0]
                    if alias in module.__dict__:
                        continue
                    try:
                        module.__dict__[alias] = importlib.import_module(import_name)
                    except Exception:
                        continue

            if stripped.startswith("from "):
                rest = stripped.removeprefix("from ")
                if " import " not in rest:
                    continue
                import_name, names = [part.strip() for part in rest.split(" import ", 1)]
                try:
                    imported_module = importlib.import_module(import_name)
                except Exception:
                    continue
                for item in names.split(","):
                    item = item.strip()
                    if not item or item == "*":
                        continue
                    if " as " in item:
                        attr_name, alias = [part.strip() for part in item.split(" as ", 1)]
                    else:
                        attr_name = item
                        alias = item
                    if alias in module.__dict__:
                        continue
                    try:
                        module.__dict__[alias] = getattr(imported_module, attr_name)
                    except Exception:
                        continue


def patch_frozen_paddlex_extra_checks() -> None:
    if not getattr(sys, "frozen", False):
        return

    try:
        from paddlex.utils import deps as paddlex_deps
    except Exception:
        return

    original_is_dep_available = paddlex_deps.is_dep_available

    module_name_map = {
        "Jinja2": ("jinja2",),
        "beautifulsoup4": ("bs4",),
        "opencv-contrib-python": ("cv2",),
        "python-bidi": ("bidi",),
        "scikit-learn": ("sklearn",),
    }

    def frozen_is_dep_available(dep: str, /, check_version: bool = False) -> bool:
        if original_is_dep_available(dep, check_version=check_version):
            return True

        import_names = module_name_map.get(dep, (dep.replace("-", "_").lower(),))
        for import_name in import_names:
            try:
                importlib.import_module(import_name)
                return True
            except Exception:
                continue
        return False

    paddlex_deps.is_dep_available = frozen_is_dep_available  # type: ignore[assignment]
    paddlex_deps.is_extra_available = lambda extra: True  # type: ignore[assignment]
    paddlex_deps.require_extra = lambda extra, *, obj_name=None, alt=None: None  # type: ignore[assignment]
    patch_loaded_paddlex_guarded_imports()


def parse_args() -> argparse.Namespace:
    default_device = normalize_device_preference(os.environ.get("PADDLE_OCR_DEVICE"))
    parser = argparse.ArgumentParser(
        description="Unified launcher for PP-OCRv5 / PP-StructureV3 batch OCR."
    )
    parser.add_argument("--root", type=str, default=None, help="Root folder to scan. Default: app directory")
    parser.add_argument("--recursive", action="store_true", help="Recursively scan subfolders")
    parser.add_argument("--pdf-dpi", type=int, default=200, help="DPI for PDF rasterization")
    parser.add_argument(
        "--image-exts",
        type=str,
        default=",".join(DEFAULT_IMAGE_EXTS),
        help="Comma-separated image extensions, e.g. .jpg,.png,.webp",
    )
    parser.add_argument(
        "--pdf-exts",
        type=str,
        default=",".join(DEFAULT_PDF_EXTS),
        help="Comma-separated PDF extensions",
    )
    parser.add_argument("--keep-pdf-images", action="store_true", help="Save rendered PDF page PNG files")
    parser.add_argument(
        "--pdf-image-dirname",
        type=str,
        default="_pdf_pages",
        help="Subfolder name for storing rendered PDF pages",
    )
    parser.add_argument(
        "--device",
        choices=DEVICE_CHOICES,
        default=default_device,
        help="Execution device. 'auto' tries the library default first and falls back to CPU on GPU init errors.",
    )
    return parser.parse_args()


def normalize_device_preference(raw: str | None) -> str:
    if not raw:
        return DEVICE_AUTO

    value = raw.strip().lower()
    if value in DEVICE_CHOICES:
        return value

    print(f"[WARN] Unsupported device preference {raw!r}. Falling back to '{DEVICE_AUTO}'.")
    return DEVICE_AUTO


def normalize_exts(raw: str) -> set[str]:
    out = set()
    for item in raw.split(","):
        s = item.strip().lower()
        if not s:
            continue
        if not s.startswith("."):
            s = "." + s
        out.add(s)
    return out


def safe_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def safe_write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")


def safe_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def try_parse_json_like(value: Any) -> Any:
    if not isinstance(value, str):
        return value

    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def normalize_json_attr(obj: Any) -> dict[str, Any]:
    if obj is None:
        return {}

    data = try_parse_json_like(obj)
    if not isinstance(data, dict):
        return {}

    # PaddleOCR/PP-Structure results are often wrapped as {"res": {...}}.
    # Some builds also keep metadata on the outer dict, so merge instead of
    # unwrapping only when "res" is the sole key.
    while isinstance(data, dict):
        res_payload = try_parse_json_like(data.get("res"))
        if not isinstance(res_payload, dict):
            break

        merged = dict(res_payload)
        for key, value in data.items():
            if key == "res":
                continue
            merged.setdefault(key, value)
        data = merged

    return data


def is_under_excluded_dir(path: Path, root: Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return True
    return any(part in EXCLUDED_DIR_NAMES for part in rel.parts[:-1])


def list_targets(root: Path, recursive: bool, image_exts: set[str], pdf_exts: set[str]) -> list[Path]:
    iterator: Iterable[Path] = root.rglob("*") if recursive else root.glob("*")
    return sorted(
        p for p in iterator
        if p.is_file()
        and p.suffix.lower() in (image_exts | pdf_exts)
        and not is_under_excluded_dir(p, root)
    )


def resolve_pending_targets(
    root: Path,
    recursive: bool,
    image_exts: set[str],
    pdf_exts: set[str],
) -> list[Path]:
    targets = list_targets(root, recursive, image_exts, pdf_exts)
    return [path for path in targets if not should_skip_generated_file(path)]


def progress_percent(completed: int, total: int) -> int:
    if total <= 0:
        return 100
    return int(round((completed / total) * 100))


class ProgressTracker:
    def __init__(self, total_steps: int) -> None:
        self.total_steps = max(total_steps, 0)
        self.completed_steps = 0

    def print_plan(
        self,
        *,
        source_file_count: int,
        selected_modes: list[str],
        text_output_layout: str,
    ) -> None:
        print("\n===== Scan Summary =====")
        print(f"Pending source files: {source_file_count}")
        print(f"Selected modes: {', '.join(selected_modes)}")
        print(f"TXT output: {describe_text_output_layout(text_output_layout)}")
        if len(selected_modes) > 1:
            print(
                "Execution steps: "
                f"{self.total_steps} ({source_file_count} files x {len(selected_modes)} modes)"
            )
        else:
            print(f"Execution steps: {self.total_steps}")
        print(f"Overall progress: {progress_percent(self.completed_steps, self.total_steps)}%")

    def start_file(self, mode: str, rel_path: Path) -> None:
        next_step = min(self.completed_steps + 1, self.total_steps)
        print(
            f"\n[PROCESS][{mode}][{next_step}/{self.total_steps} | "
            f"{progress_percent(self.completed_steps, self.total_steps)}%] {rel_path}"
        )

    def finish_file(self, mode: str, rel_path: Path, status: str) -> None:
        if self.completed_steps < self.total_steps:
            self.completed_steps += 1
        print(
            f"[PROGRESS][{mode}] {progress_percent(self.completed_steps, self.total_steps)}% "
            f"({self.completed_steps}/{self.total_steps}) - {status}: {rel_path}"
        )

    def skip_mode(self, mode: str, file_count: int, reason: str) -> None:
        if file_count <= 0:
            return
        self.completed_steps = min(self.total_steps, self.completed_steps + file_count)
        print(
            f"[PROGRESS][{mode}] {progress_percent(self.completed_steps, self.total_steps)}% "
            f"({self.completed_steps}/{self.total_steps}) - skipped {file_count} files: {reason}"
        )


def render_pdf_pages(
    pdf_path: Path,
    dpi: int,
    keep_images: bool,
    pdf_image_dirname: str,
) -> Iterable[tuple[int, bytes, str | None]]:
    doc = fitz.open(pdf_path)
    scale = dpi / 72.0
    matrix = fitz.Matrix(scale, scale)
    image_dir = pdf_path.parent / pdf_image_dirname / pdf_path.stem
    try:
        for page_index, page in enumerate(doc):
            pix = page.get_pixmap(matrix=matrix, alpha=False)
            png_bytes = pix.tobytes("png")
            saved_path = None
            if keep_images:
                image_dir.mkdir(parents=True, exist_ok=True)
                img_path = image_dir / f"{pdf_path.stem}_page_{page_index + 1:04d}.png"
                img_path.write_bytes(png_bytes)
                saved_path = str(img_path)
            yield page_index, png_bytes, saved_path
    finally:
        doc.close()


def filter_ocr_payload(payload: dict, score_thresh: float) -> dict:
    rec_texts = payload.get("rec_texts", []) or []
    rec_scores = payload.get("rec_scores", []) or []
    rec_polys = payload.get("rec_polys", []) or []

    kept_texts = []
    kept_scores = []
    kept_polys = []

    for i, text in enumerate(rec_texts):
        text = str(text).strip()
        score = float(rec_scores[i]) if i < len(rec_scores) else 0.0
        poly = rec_polys[i] if i < len(rec_polys) else None

        if text and score >= score_thresh:
            kept_texts.append(text)
            kept_scores.append(score)
            kept_polys.append(poly)

    new_payload = dict(payload)
    new_payload["rec_texts"] = kept_texts
    new_payload["rec_scores"] = kept_scores
    new_payload["rec_polys"] = kept_polys
    new_payload["text_rec_score_thresh_applied"] = score_thresh
    return new_payload


def find_first_nested_text(obj: Any, keys: tuple[str, ...]) -> str | None:
    if isinstance(obj, dict):
        for key in keys:
            value = obj.get(key)
            if isinstance(value, str):
                text = value.strip()
                if text:
                    return text
            elif isinstance(value, list):
                chunks = [item.strip() for item in value if isinstance(item, str) and item.strip()]
                if chunks:
                    return "\n\n".join(chunks)

        for value in obj.values():
            found = find_first_nested_text(value, keys)
            if found:
                return found

    elif isinstance(obj, list):
        for item in obj:
            found = find_first_nested_text(item, keys)
            if found:
                return found

    return None


def normalize_structure_text(text: str) -> str:
    cleaned = html.unescape(text.replace("\r\n", "\n").replace("\r", "\n"))
    replacements = (
        (r"(?is)<br\s*/?>", "\n"),
        (r"(?is)</(?:p|div|section|article|h[1-6]|ul|ol|li)>", "\n"),
        (r"(?is)</(?:table|thead|tbody|tfoot)>", "\n"),
        (r"(?is)</tr>", "\n"),
        (r"(?is)</t[dh]>", "\t"),
        (r"(?is)<(?:table|thead|tbody|tfoot|tr|p|div|section|article|h[1-6]|ul|ol|li)\b[^>]*>", ""),
        (r"(?is)<t[dh]\b[^>]*>", ""),
        (r"(?is)<[^>]+>", ""),
    )
    for pattern, replacement in replacements:
        cleaned = re.sub(pattern, replacement, cleaned)

    lines: list[str] = []
    for raw_line in cleaned.split("\n"):
        line = raw_line.replace("\xa0", " ")
        if "\t" in line:
            cells = [re.sub(r"\s+", " ", cell).strip() for cell in line.split("\t")]
            normalized = "\t".join(cell for cell in cells if cell)
        else:
            normalized = re.sub(r"\s+", " ", line).strip()

        if not normalized:
            if lines and lines[-1] != "":
                lines.append("")
            continue
        lines.append(normalized)

    return "\n".join(lines).strip()


def split_structure_text_blocks(text: str) -> list[str]:
    return dedupe_keep_order(
        [block.strip() for block in re.split(r"\n{2,}", text) if block.strip()]
    )


def get_structure_markdown_payload(result: Any) -> dict[str, Any]:
    markdown_method = getattr(result, "_to_markdown", None)
    if callable(markdown_method):
        try:
            payload = markdown_method(pretty=False)
            if isinstance(payload, dict):
                return normalize_json_attr(payload)
        except Exception:
            pass

    try:
        payload = getattr(result, "markdown", None)
    except Exception:
        payload = None

    if isinstance(payload, dict):
        return normalize_json_attr(payload)

    return {}


def extract_structure_texts(result: Any, payload: dict[str, Any], score_thresh: float) -> list[str]:
    for candidate in (get_structure_markdown_payload(result), payload):
        markdown_text = find_first_nested_text(candidate, ("markdown_texts",))
        if not markdown_text:
            continue

        blocks = split_structure_text_blocks(normalize_structure_text(markdown_text))
        if blocks:
            return blocks

    texts: list[str] = []
    extract_texts_deep(payload, score_thresh, texts)
    return dedupe_keep_order(texts)


def extract_texts_deep(obj: Any, score_thresh: float, out: list[str]) -> None:
    if isinstance(obj, dict):
        if "rec_texts" in obj:
            texts = obj.get("rec_texts", []) or []
            scores = obj.get("rec_scores", []) or []
            for i, text in enumerate(texts):
                s = str(text).strip()
                score = float(scores[i]) if i < len(scores) else 0.0
                if s and score >= score_thresh:
                    out.append(s)

        for key in ("markdown_texts", "text", "markdown", "content"):
            val = obj.get(key)
            if isinstance(val, str):
                s = val.strip()
                if s:
                    out.append(s)
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, str):
                        s = item.strip()
                        if s:
                            out.append(s)

        for v in obj.values():
            extract_texts_deep(v, score_thresh, out)

    elif isinstance(obj, list):
        for item in obj:
            extract_texts_deep(item, score_thresh, out)


def dedupe_keep_order(items: list[str]) -> list[str]:
    seen = set()
    out = []
    for x in items:
        s = x.strip()
        if s and s not in seen:
            seen.add(s)
            out.append(s)
    return out


def results_to_text(mode: str, results: list[dict]) -> str:
    parts: list[str] = []
    for item in results:
        page = item.get("page_index")
        if page is not None:
            parts.append(f"===== PAGE {page + 1} =====")

        if mode == MODE_OCR:
            texts = item.get("rec_texts", []) or []
        else:
            texts = item.get("_extracted_texts", []) or []

        parts.extend(str(t).strip() for t in texts if str(t).strip())
        parts.append("")
    return "\n".join(parts).strip()


def make_stem_with_relpath(src: Path, root: Path) -> str:
    rel = src.relative_to(root)
    rel_no_suffix = rel.with_suffix("")
    return "__".join(rel_no_suffix.parts)


def output_paths(src: Path, root: Path, mode: str) -> tuple[Path, Path]:
    stem = make_stem_with_relpath(src, root)
    txt = src.parent / f"{stem}.{mode}.txt"
    js = src.parent / f"{stem}.{mode}.json"
    return txt, js


def describe_text_output_layout(text_output_layout: str) -> str:
    if text_output_layout == TEXT_LAYOUT_KNOWLEDGEBASE:
        return "one <folder>knowledgebase.txt per folder"
    return "one TXT per source image/PDF"


def knowledgebase_output_paths(folder: Path) -> tuple[Path, Path]:
    folder_name = folder.name.strip()
    if not folder_name:
        folder_name = folder.drive.rstrip("\\/:").replace(":", "") or "root"

    txt_path = folder / f"{folder_name}knowledgebase.txt"
    jsonl_path = folder / f"{folder_name}knowledgebase.jsonl"
    return txt_path, jsonl_path


def build_folder_kb(
    folder: Path,
    output_mode: str,
    records: list[dict[str, Any]],
) -> tuple[Path, Path]:
    kb_txt_path, kb_jsonl_path = knowledgebase_output_paths(folder)
    active_modes = {
        str(record.get("mode", "")).strip()
        for record in records
        if str(record.get("mode", "")).strip()
    }
    include_mode_label = len(active_modes) > 1

    txt_sections: list[str] = []
    jsonl_lines: list[str] = []

    for record in records:
        content = str(record.get("text", "")).strip()
        if not content:
            continue

        source_label = str(record.get("source_label", "")).strip()
        if not source_label:
            source_file = record.get("source_file")
            if isinstance(source_file, str) and source_file.strip():
                source_label = Path(source_file).name
        if not source_label:
            source_label = "unknown"

        section_title = source_label
        mode = str(record.get("mode", "")).strip()
        if include_mode_label and mode:
            section_title = f"[{mode}] {section_title}"

        txt_sections.append(f"## {section_title}\n{content}\n")
        jsonl_lines.append(json.dumps(record, ensure_ascii=False))

    safe_write_text(kb_txt_path, "\n".join(txt_sections).strip())
    if writes_json_output(output_mode):
        safe_write_text(kb_jsonl_path, "\n".join(jsonl_lines).strip())
    else:
        safe_unlink(kb_jsonl_path)
    return kb_txt_path, kb_jsonl_path


def ask_mode() -> str:
    print("\nChoose mode:")
    print("1. PP-OCRv5")
    print("2. PP-StructureV3")
    print("3. Run both")
    while True:
        choice = input("Enter 1 / 2 / 3: ").strip()
        if choice == "1":
            return MODE_OCR
        if choice == "2":
            return MODE_STRUCTURE
        if choice == "3":
            return "both"
        print("Invalid input. Please enter 1, 2, or 3.")


def ask_scan_target() -> str:
    print("\nChoose file types to scan:")
    print("1. picture (JPG / PNG / BMP / WEBP)")
    print("2. PDF")
    print("3. picture + PDF")
    while True:
        choice = input("Enter 1 / 2 / 3 (Enter for default 3): ").strip()
        if choice == "" or choice == "3":
            return SCAN_PICTURES_PDF
        if choice == "1":
            return SCAN_PICTURES
        if choice == "2":
            return SCAN_PDF
        print("Invalid input. Please enter 1, 2, or 3.")


def select_scan_exts(scan_target: str, image_exts: set[str], pdf_exts: set[str]) -> tuple[set[str], set[str]]:
    prompt_image_exts = image_exts & PROMPT_PICTURE_EXTS
    if not prompt_image_exts:
        prompt_image_exts = set(PROMPT_PICTURE_EXTS)

    if scan_target == SCAN_PICTURES:
        return prompt_image_exts, set()
    if scan_target == SCAN_PDF:
        return set(), set(pdf_exts)
    return prompt_image_exts, set(pdf_exts)


def ask_score_threshold(default: float = 0.70) -> float:
    presets = ["0.50", "0.60", "0.70", "0.80", "0.90", "Custom"]
    print("\nChoose confidence threshold:")
    for i, p in enumerate(presets, start=1):
        print(f"{i}. {p}")

    while True:
        choice = input(f"Enter 1 to 6 (Enter for default {default:.2f}): ").strip()
        if choice == "":
            return default

        mapping = {
            "1": 0.50,
            "2": 0.60,
            "3": 0.70,
            "4": 0.80,
            "5": 0.90,
        }
        if choice in mapping:
            return mapping[choice]

        if choice == "6":
            raw = input("Enter a value between 0.00 and 1.00: ").strip()
            try:
                value = float(raw)
                if 0.0 <= value <= 1.0:
                    return value
            except ValueError:
                pass
            print("Invalid custom value. Try again.")
            continue

        print("Invalid input. Please enter 1 to 6.")


def ask_text_output_layout() -> str:
    print("\nChoose TXT output layout:")
    print("1. One TXT per image / PDF")
    print("2. One <folder>knowledgebase.txt per folder")
    while True:
        choice = input("Enter 1 / 2 (Enter for default 1): ").strip()
        if choice == "" or choice == "1":
            return TEXT_LAYOUT_PER_FILE
        if choice == "2":
            return TEXT_LAYOUT_KNOWLEDGEBASE
        print("Invalid input. Please enter 1 or 2.")




def ask_output_mode() -> str:
    print("\nChoose output format:")
    print("1. TXT only")
    print("2. TXT + JSON")
    while True:
        choice = input("Enter 1 / 2 (Enter for default 2): ").strip()
        if choice == "" or choice == "2":
            return OUTPUT_TXT_JSON
        if choice == "1":
            return OUTPUT_TXT_ONLY
        print("Invalid input. Please enter 1 or 2.")


def writes_json_output(output_mode: str) -> bool:
    return output_mode == OUTPUT_TXT_JSON


def iter_exception_chain(exc: BaseException) -> Iterable[BaseException]:
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        yield current
        current = current.__cause__ or current.__context__


def exception_chain_text(exc: BaseException) -> str:
    return " | ".join(f"{type(item).__name__}: {item}" for item in iter_exception_chain(exc))


def is_gpu_init_error(exc: BaseException) -> bool:
    message = exception_chain_text(exc).lower()
    hints = (
        "unsupported gpu architecture",
        "mismatched gpu architecture",
        "is not compiled with cuda",
        "gpu is not available",
        "cannot use gpu",
        "cuda error",
        "cudnn",
    )
    return any(hint in message for hint in hints)


def is_onednn_runtime_error(exc: BaseException) -> bool:
    message = exception_chain_text(exc).lower()
    hints = (
        "onednn",
        "mkldnn",
        "pir",
        "onednn_instruction.cc",
        "convertpirattribute2runtimeattribute",
        "runtimeattribute",
        "could not execute a primitive",
        "pir interpreter",
        "pir kernel",
    )
    return any(hint in message for hint in hints)


def format_pipeline_init_error(mode: str, exc: BaseException, device_preference: str) -> str:
    detail = exception_chain_text(exc)
    message = detail.lower()

    if device_preference in {DEVICE_AUTO, DEVICE_GPU} and is_gpu_init_error(exc):
        return (
            f"{detail}\n"
            f"The installed PaddlePaddle GPU wheel cannot run on this GPU. "
            f"Use '--device {DEVICE_CPU}' or 'start_ocr_launcher.ps1 -Device CPU'."
        )

    if "dependency error occurred during pipeline creation" in message or "dependencyerror" in message:
        if mode == MODE_STRUCTURE:
            return (
                f"{detail}\n"
                "PP-StructureV3 dependencies are incomplete in this .venv. "
                "Run 'install_manual_recovery.ps1' or install 'paddlex[ocr]==3.4.2'."
            )
        return detail

    return detail


def force_cpu_runtime(*, disable_mkldnn: bool = False) -> None:
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    if disable_mkldnn:
        os.environ["PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT"] = "False"
        os.environ["FLAGS_use_mkldnn"] = "0"
    try:
        import paddle

        paddle.device.set_device(DEVICE_CPU)
    except Exception:
        pass


def pipeline_accepts_kwarg(factory: Any, kwarg_name: str) -> bool:
    try:
        signature = inspect.signature(factory)
    except (TypeError, ValueError):
        return False

    if kwarg_name in signature.parameters:
        return True

    return any(
        parameter.kind == inspect.Parameter.VAR_KEYWORD
        for parameter in signature.parameters.values()
    )


def build_pipeline(mode: str, device: str | None, *, disable_mkldnn: bool = False):
    PaddleOCR, PPStructureV3 = load_paddle_entrypoints()
    pipeline_factory = PaddleOCR if mode == MODE_OCR else PPStructureV3
    pipeline_kwargs: dict[str, Any] = {}
    if device:
        pipeline_kwargs["device"] = device
    if (device == DEVICE_CPU or disable_mkldnn) and pipeline_accepts_kwarg(
        pipeline_factory, "enable_mkldnn"
    ):
        pipeline_kwargs["enable_mkldnn"] = False

    if mode == MODE_OCR:
        return pipeline_factory(
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
            text_rec_score_thresh=0.0,
            **pipeline_kwargs,
        )

    return pipeline_factory(**pipeline_kwargs)


def create_mode_pipeline(mode: str, device_preference: str):
    initial_device = None if device_preference == DEVICE_AUTO else device_preference

    try:
        mkldnn_disabled = initial_device == DEVICE_CPU
        if initial_device == DEVICE_CPU:
            force_cpu_runtime(disable_mkldnn=True)
        pipeline = build_pipeline(mode, initial_device, disable_mkldnn=mkldnn_disabled)
        runtime_device = device_preference if initial_device else "auto (library default)"
        return {
            "pipeline": pipeline,
            "runtime_device": runtime_device,
            "mkldnn_disabled": mkldnn_disabled,
        }
    except Exception as exc:
        if device_preference != DEVICE_AUTO or not is_gpu_init_error(exc):
            raise

        print(f"[WARN][{mode}] GPU initialization failed. Retrying on CPU.")
        print(f"  Detail: {exception_chain_text(exc)}")
        force_cpu_runtime(disable_mkldnn=True)
        pipeline = build_pipeline(mode, DEVICE_CPU, disable_mkldnn=True)
        return {
            "pipeline": pipeline,
            "runtime_device": "cpu (fallback, mkldnn disabled)",
            "mkldnn_disabled": True,
        }


def rebuild_runtime_with_cpu_retry(mode: str, runtime_state: dict[str, Any], exc: BaseException) -> None:
    print(
        f"[WARN][{mode}] oneDNN / PIR runtime failed. "
        "Retrying with a fresh CPU pipeline and MKLDNN disabled."
    )
    print(f"  Detail: {exception_chain_text(exc)}")
    force_cpu_runtime(disable_mkldnn=True)
    runtime_state["pipeline"] = build_pipeline(mode, DEVICE_CPU, disable_mkldnn=True)
    runtime_state["runtime_device"] = "cpu (onednn/pir retry, mkldnn disabled)"
    runtime_state["mkldnn_disabled"] = True
    print(f"  Runtime device: {runtime_state['runtime_device']}")


def predict_with_runtime_retry(mode: str, runtime_state: dict[str, Any], input_data: Any):
    for attempt in range(2):
        try:
            return runtime_state["pipeline"].predict(input_data)
        except Exception as exc:
            if attempt >= 1 or not is_onednn_runtime_error(exc):
                raise
            rebuild_runtime_with_cpu_retry(mode, runtime_state, exc)


def should_skip_generated_file(path: Path) -> bool:
    generated_suffixes = (
        f".{MODE_OCR}.txt",
        f".{MODE_OCR}.json",
        f".{MODE_STRUCTURE}.txt",
        f".{MODE_STRUCTURE}.json",
    )
    return (
        path.name.endswith(generated_suffixes)
        or path.name.endswith(".knowledgebase.txt")
        or path.name.endswith(".knowledgebase.jsonl")
    )


def run_mode(
    mode: str,
    root: Path,
    targets: list[Path],
    recursive: bool,
    score_thresh: float,
    output_mode: str,
    text_output_layout: str,
    device_preference: str,
    pdf_dpi: int,
    keep_pdf_images: bool,
    pdf_image_dirname: str,
    image_exts: set[str],
    pdf_exts: set[str],
    folder_kb_records: dict[Path, list[dict[str, Any]]] | None = None,
    folder_kb_touched_folders: set[Path] | None = None,
    progress_tracker: ProgressTracker | None = None,
) -> bool:
    emit_json = writes_json_output(output_mode)
    write_per_file_text = text_output_layout == TEXT_LAYOUT_PER_FILE
    patch_frozen_paddlex_extra_checks()

    print(f"\n===== Start {mode} =====")
    print(f"Root: {root}")
    print(f"Recursive: {recursive}")
    print(f"Targets: {len(targets)}")
    print(f"Image types: {', '.join(sorted(image_exts)) if image_exts else '(disabled)'}")
    print(f"PDF types: {', '.join(sorted(pdf_exts)) if pdf_exts else '(disabled)'}")
    print(f"Score threshold: {score_thresh}")
    print(f"Output mode: {output_mode}")
    print(f"TXT output layout: {describe_text_output_layout(text_output_layout)}")
    print(f"Device preference: {device_preference}")
    print(f"Keep PDF images: {keep_pdf_images}")

    try:
        runtime_state = create_mode_pipeline(mode, device_preference)
        pipeline = runtime_state["pipeline"]
        runtime_device = runtime_state["runtime_device"]
        print(f"Runtime device: {runtime_device}")
    except Exception as exc:
        print(f"[INIT FAIL][{mode}] {format_pipeline_init_error(mode, exc, device_preference)}")
        if progress_tracker is not None:
            progress_tracker.skip_mode(mode, len(targets), "pipeline initialization failed")
        print(f"\n===== {mode} skipped =====")
        return False

    if folder_kb_records is None:
        folder_kb_records = {}
    if folder_kb_touched_folders is None:
        folder_kb_touched_folders = set()

    for src in targets:
        rel = src.relative_to(root)
        if progress_tracker is not None:
            progress_tracker.start_file(mode, rel)
        else:
            print(f"\n[PROCESS][{mode}] {rel}")

        out_txt, out_json = output_paths(src, root, mode)
        if not write_per_file_text:
            folder_kb_touched_folders.add(src.parent)
        per_page_results: list[dict] = []
        status = "done"

        try:
            if src.suffix.lower() in image_exts:
                results = predict_with_runtime_retry(mode, runtime_state, str(src))
                pipeline = runtime_state["pipeline"]
                for res in results:
                    payload = normalize_json_attr(getattr(res, "json", None))
                    if mode == MODE_OCR:
                        payload = filter_ocr_payload(payload, score_thresh)
                    else:
                        payload["_extracted_texts"] = extract_structure_texts(
                            res, payload, score_thresh
                        )
                    per_page_results.append(payload)

            elif src.suffix.lower() in pdf_exts:
                for page_index, png_bytes, saved_img_path in render_pdf_pages(
                    src,
                    dpi=pdf_dpi,
                    keep_images=keep_pdf_images,
                    pdf_image_dirname=pdf_image_dirname,
                ):
                    results = predict_with_runtime_retry(mode, runtime_state, png_bytes)
                    pipeline = runtime_state["pipeline"]
                    for res in results:
                        payload = normalize_json_attr(getattr(res, "json", None))
                        if mode == MODE_OCR:
                            payload = filter_ocr_payload(payload, score_thresh)
                        else:
                            payload["_extracted_texts"] = extract_structure_texts(
                                res, payload, score_thresh
                            )

                        payload["page_index"] = page_index
                        payload["rendered_page_image"] = saved_img_path
                        per_page_results.append(payload)

            text_output = results_to_text(mode, per_page_results)
            result_payload = {
                "source_file": str(src),
                "mode": mode,
                "text_score_thresh": score_thresh,
                "pdf_render_dpi": pdf_dpi,
                "keep_pdf_images": keep_pdf_images,
                "results": per_page_results,
            }

            if write_per_file_text:
                safe_write_text(out_txt, text_output)
                if emit_json:
                    safe_write_json(out_json, result_payload)
                else:
                    safe_unlink(out_json)

                print(f"  TXT  -> {out_txt.name}")
                if emit_json:
                    print(f"  JSON -> {out_json.name}")
                else:
                    print("  JSON -> skipped (TXT only)")
            else:
                folder_kb_records.setdefault(src.parent, []).append(
                    {
                        "mode": mode,
                        "folder": str(src.parent),
                        "source_file": str(src),
                        "source_label": src.name,
                        "status": status,
                        "text": text_output,
                        "meta": result_payload if emit_json else {},
                    }
                )
                kb_txt_path, kb_jsonl_path = knowledgebase_output_paths(src.parent)
                print(f"  TXT  -> queued for {kb_txt_path.name}")
                if emit_json:
                    print(f"  JSON -> queued for {kb_jsonl_path.name}")
                else:
                    print("  JSON -> skipped (TXT only)")

        except Exception as e:
            error_text = f"[ERROR]\n{type(e).__name__}: {e}\n"
            error_payload = {
                "source_file": str(src),
                "mode": mode,
                "error": f"{type(e).__name__}: {e}",
            }
            if write_per_file_text:
                safe_write_text(out_txt, error_text)
                if emit_json:
                    safe_write_json(out_json, error_payload)
                else:
                    safe_unlink(out_json)
            else:
                folder_kb_records.setdefault(src.parent, []).append(
                    {
                        "mode": mode,
                        "folder": str(src.parent),
                        "source_file": str(src),
                        "source_label": src.name,
                        "status": "failed",
                        "text": error_text,
                        "meta": error_payload if emit_json else {},
                    }
                )
            print(f"  FAIL -> {type(e).__name__}: {e}")
            status = "failed"
        finally:
            if progress_tracker is not None:
                progress_tracker.finish_file(mode, rel, status)

    print(f"\n===== {mode} done =====")
    return True


def main() -> int:
    args = parse_args()
    app_root = get_app_root()
    configure_frozen_runtime_paths()
    import_bundled_model_cache()
    root = Path(args.root).resolve() if args.root else app_root

    image_exts = normalize_exts(args.image_exts)
    pdf_exts = normalize_exts(args.pdf_exts)

    scan_target = ask_scan_target()
    image_exts, pdf_exts = select_scan_exts(scan_target, image_exts, pdf_exts)
    mode = ask_mode()
    score_thresh = ask_score_threshold(default=0.70)
    text_output_layout = ask_text_output_layout()
    output_mode = ask_output_mode()
    selected_modes: list[str] = []
    if mode in {MODE_OCR, "both"}:
        selected_modes.append(MODE_OCR)
    if mode in {MODE_STRUCTURE, "both"}:
        selected_modes.append(MODE_STRUCTURE)

    targets = resolve_pending_targets(
        root=root,
        recursive=args.recursive,
        image_exts=image_exts,
        pdf_exts=pdf_exts,
    )
    if not targets:
        print("\n===== Scan Summary =====")
        print(f"Root: {root}")
        print(f"Recursive: {args.recursive}")
        print("Pending source files: 0")
        print("No matching files were found. Nothing to do.")
        return 0

    folder_kb_records: dict[Path, list[dict[str, Any]]] = {}
    folder_kb_touched_folders: set[Path] = set()
    progress_tracker = ProgressTracker(total_steps=len(targets) * len(selected_modes))
    progress_tracker.print_plan(
        source_file_count=len(targets),
        selected_modes=selected_modes,
        text_output_layout=text_output_layout,
    )
    succeeded_modes: list[str] = []
    failed_modes: list[str] = []

    if mode in {MODE_OCR, "both"}:
        if run_mode(
            mode=MODE_OCR,
            root=root,
            targets=targets,
            recursive=args.recursive,
            score_thresh=score_thresh,
            output_mode=output_mode,
            text_output_layout=text_output_layout,
            device_preference=args.device,
            pdf_dpi=args.pdf_dpi,
            keep_pdf_images=args.keep_pdf_images,
            pdf_image_dirname=args.pdf_image_dirname,
            image_exts=image_exts,
            pdf_exts=pdf_exts,
            folder_kb_records=folder_kb_records,
            folder_kb_touched_folders=folder_kb_touched_folders,
            progress_tracker=progress_tracker,
        ):
            succeeded_modes.append(MODE_OCR)
        else:
            failed_modes.append(MODE_OCR)

    if mode in {MODE_STRUCTURE, "both"}:
        if run_mode(
            mode=MODE_STRUCTURE,
            root=root,
            targets=targets,
            recursive=args.recursive,
            score_thresh=score_thresh,
            output_mode=output_mode,
            text_output_layout=text_output_layout,
            device_preference=args.device,
            pdf_dpi=args.pdf_dpi,
            keep_pdf_images=args.keep_pdf_images,
            pdf_image_dirname=args.pdf_image_dirname,
            image_exts=image_exts,
            pdf_exts=pdf_exts,
            folder_kb_records=folder_kb_records,
            folder_kb_touched_folders=folder_kb_touched_folders,
            progress_tracker=progress_tracker,
        ):
            succeeded_modes.append(MODE_STRUCTURE)
        else:
            failed_modes.append(MODE_STRUCTURE)

    if text_output_layout == TEXT_LAYOUT_KNOWLEDGEBASE:
        emit_json = writes_json_output(output_mode)
        for folder in sorted(folder_kb_touched_folders):
            kb_txt_path, kb_jsonl_path = build_folder_kb(
                folder,
                output_mode,
                folder_kb_records.get(folder, []),
            )
            print(f"[KB] {kb_txt_path}")
            if emit_json:
                print(f"[KB] {kb_jsonl_path}")

    if failed_modes and succeeded_modes:
        print("\nCompleted with warnings.")
        print(f"Succeeded: {', '.join(succeeded_modes)}")
        print(f"Skipped: {', '.join(failed_modes)}")
        return 0

    if failed_modes:
        print("\nNo requested modes completed successfully.")
        print(f"Failed: {', '.join(failed_modes)}")
        return 1

    print("\nAll done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
