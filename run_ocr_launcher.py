from __future__ import annotations

import argparse
import importlib
import importlib.util
import json
import os
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


def normalize_json_attr(obj: Any) -> dict:
    if obj is None:
        return {}
    if isinstance(obj, dict):
        data = obj
    elif isinstance(obj, str):
        try:
            data = json.loads(obj)
        except json.JSONDecodeError:
            return {}
    else:
        return {}

    # PaddleOCR/PP-Structure results are often wrapped as {"res": {...}}.
    while isinstance(data, dict) and "res" in data and isinstance(data["res"], dict):
        wrapper_keys = {key for key in data.keys() if key != "res"}
        if wrapper_keys:
            break
        data = data["res"]

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

        for key in ("text", "markdown", "content"):
            val = obj.get(key)
            if isinstance(val, str):
                s = val.strip()
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


def build_folder_kb(folder: Path, mode: str, output_mode: str) -> None:
    txt_tail = f".{mode}.txt"
    json_tail = f".{mode}.json"
    kb_jsonl_path = folder / f"{mode}.knowledgebase.jsonl"

    txt_files = sorted(
        p for p in folder.iterdir()
        if p.is_file()
        and p.name.endswith(txt_tail)
        and p.name != f"{mode}.knowledgebase.txt"
    )

    txt_sections: list[str] = []
    jsonl_lines: list[str] = []

    for txt_path in txt_files:
        content = txt_path.read_text(encoding="utf-8", errors="ignore").strip()
        if not content:
            continue

        txt_sections.append(f"## {txt_path.name}\n{content}\n")

        json_path = txt_path.with_name(txt_path.name.replace(txt_tail, json_tail))
        payload: dict[str, Any] = {}
        if json_path.exists():
            try:
                payload = json.loads(json_path.read_text(encoding="utf-8"))
            except Exception:
                payload = {}

        record = {
            "mode": mode,
            "source_txt": str(txt_path),
            "source_json": str(json_path) if json_path.exists() else None,
            "folder": str(folder),
            "text": content,
            "meta": payload,
        }
        jsonl_lines.append(json.dumps(record, ensure_ascii=False))

    safe_write_text(folder / f"{mode}.knowledgebase.txt", "\n".join(txt_sections).strip())
    if writes_json_output(output_mode):
        safe_write_text(kb_jsonl_path, "\n".join(jsonl_lines).strip())
    else:
        safe_unlink(kb_jsonl_path)


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


def force_cpu_runtime() -> None:
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    try:
        import paddle

        paddle.device.set_device(DEVICE_CPU)
    except Exception:
        pass


def build_pipeline(mode: str, device: str | None):
    PaddleOCR, PPStructureV3 = load_paddle_entrypoints()
    pipeline_kwargs: dict[str, Any] = {}
    if device:
        pipeline_kwargs["device"] = device

    if mode == MODE_OCR:
        return PaddleOCR(
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
            text_rec_score_thresh=0.0,
            **pipeline_kwargs,
        )

    return PPStructureV3(**pipeline_kwargs)


def create_mode_pipeline(mode: str, device_preference: str):
    initial_device = None if device_preference == DEVICE_AUTO else device_preference

    try:
        if initial_device == DEVICE_CPU:
            force_cpu_runtime()
        pipeline = build_pipeline(mode, initial_device)
        runtime_device = device_preference if initial_device else "auto (library default)"
        return pipeline, runtime_device
    except Exception as exc:
        if device_preference != DEVICE_AUTO or not is_gpu_init_error(exc):
            raise

        print(f"[WARN][{mode}] GPU initialization failed. Retrying on CPU.")
        print(f"  Detail: {exception_chain_text(exc)}")
        force_cpu_runtime()
        pipeline = build_pipeline(mode, DEVICE_CPU)
        return pipeline, "cpu (fallback)"


def should_skip_generated_file(path: Path) -> bool:
    generated_suffixes = (
        f".{MODE_OCR}.txt",
        f".{MODE_OCR}.json",
        f".{MODE_STRUCTURE}.txt",
        f".{MODE_STRUCTURE}.json",
    )
    generated_names = {
        f"{MODE_OCR}.knowledgebase.txt",
        f"{MODE_OCR}.knowledgebase.jsonl",
        f"{MODE_STRUCTURE}.knowledgebase.txt",
        f"{MODE_STRUCTURE}.knowledgebase.jsonl",
    }
    return path.name in generated_names or path.name.endswith(generated_suffixes)


def run_mode(
    mode: str,
    root: Path,
    recursive: bool,
    score_thresh: float,
    output_mode: str,
    device_preference: str,
    pdf_dpi: int,
    keep_pdf_images: bool,
    pdf_image_dirname: str,
    image_exts: set[str],
    pdf_exts: set[str],
) -> bool:
    emit_json = writes_json_output(output_mode)
    patch_frozen_paddlex_extra_checks()
    targets = list_targets(root, recursive, image_exts, pdf_exts)
    targets = [p for p in targets if not should_skip_generated_file(p)]

    print(f"\n===== Start {mode} =====")
    print(f"Root: {root}")
    print(f"Recursive: {recursive}")
    print(f"Targets: {len(targets)}")
    print(f"Image types: {', '.join(sorted(image_exts)) if image_exts else '(disabled)'}")
    print(f"PDF types: {', '.join(sorted(pdf_exts)) if pdf_exts else '(disabled)'}")
    print(f"Score threshold: {score_thresh}")
    print(f"Output mode: {output_mode}")
    print(f"Device preference: {device_preference}")
    print(f"Keep PDF images: {keep_pdf_images}")

    try:
        pipeline, runtime_device = create_mode_pipeline(mode, device_preference)
        print(f"Runtime device: {runtime_device}")
    except Exception as exc:
        print(f"[INIT FAIL][{mode}] {format_pipeline_init_error(mode, exc, device_preference)}")
        print(f"\n===== {mode} skipped =====")
        return False

    touched_folders: set[Path] = set()

    for src in targets:
        rel = src.relative_to(root)
        print(f"\n[PROCESS][{mode}] {rel}")

        out_txt, out_json = output_paths(src, root, mode)
        touched_folders.add(src.parent)
        per_page_results: list[dict] = []

        try:
            if src.suffix.lower() in image_exts:
                results = pipeline.predict(str(src))
                for res in results:
                    payload = normalize_json_attr(getattr(res, "json", None))
                    if mode == MODE_OCR:
                        payload = filter_ocr_payload(payload, score_thresh)
                    else:
                        texts: list[str] = []
                        extract_texts_deep(payload, score_thresh, texts)
                        payload["_extracted_texts"] = dedupe_keep_order(texts)
                    per_page_results.append(payload)

            elif src.suffix.lower() in pdf_exts:
                for page_index, png_bytes, saved_img_path in render_pdf_pages(
                    src,
                    dpi=pdf_dpi,
                    keep_images=keep_pdf_images,
                    pdf_image_dirname=pdf_image_dirname,
                ):
                    results = pipeline.predict(png_bytes)
                    for res in results:
                        payload = normalize_json_attr(getattr(res, "json", None))
                        if mode == MODE_OCR:
                            payload = filter_ocr_payload(payload, score_thresh)
                        else:
                            texts: list[str] = []
                            extract_texts_deep(payload, score_thresh, texts)
                            payload["_extracted_texts"] = dedupe_keep_order(texts)

                        payload["page_index"] = page_index
                        payload["rendered_page_image"] = saved_img_path
                        per_page_results.append(payload)

            text_output = results_to_text(mode, per_page_results)
            safe_write_text(out_txt, text_output)
            if emit_json:
                safe_write_json(
                    out_json,
                    {
                        "source_file": str(src),
                        "mode": mode,
                        "text_score_thresh": score_thresh,
                        "pdf_render_dpi": pdf_dpi,
                        "keep_pdf_images": keep_pdf_images,
                        "results": per_page_results,
                    },
                )
            else:
                safe_unlink(out_json)

            print(f"  TXT  -> {out_txt.name}")
            if emit_json:
                print(f"  JSON -> {out_json.name}")
            else:
                print("  JSON -> skipped (TXT only)")

        except Exception as e:
            safe_write_text(out_txt, f"[ERROR]\n{type(e).__name__}: {e}\n")
            if emit_json:
                safe_write_json(
                    out_json,
                    {
                        "source_file": str(src),
                        "mode": mode,
                        "error": f"{type(e).__name__}: {e}",
                    },
                )
            else:
                safe_unlink(out_json)
            print(f"  FAIL -> {type(e).__name__}: {e}")

    for folder in sorted(touched_folders):
        build_folder_kb(folder, mode, output_mode)
        print(f"[KB] {folder / f'{mode}.knowledgebase.txt'}")
        if emit_json:
            print(f"[KB] {folder / f'{mode}.knowledgebase.jsonl'}")

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
    output_mode = ask_output_mode()
    succeeded_modes: list[str] = []
    failed_modes: list[str] = []

    if mode in {MODE_OCR, "both"}:
        if run_mode(
            mode=MODE_OCR,
            root=root,
            recursive=args.recursive,
            score_thresh=score_thresh,
            output_mode=output_mode,
            device_preference=args.device,
            pdf_dpi=args.pdf_dpi,
            keep_pdf_images=args.keep_pdf_images,
            pdf_image_dirname=args.pdf_image_dirname,
            image_exts=image_exts,
            pdf_exts=pdf_exts,
        ):
            succeeded_modes.append(MODE_OCR)
        else:
            failed_modes.append(MODE_OCR)

    if mode in {MODE_STRUCTURE, "both"}:
        if run_mode(
            mode=MODE_STRUCTURE,
            root=root,
            recursive=args.recursive,
            score_thresh=score_thresh,
            output_mode=output_mode,
            device_preference=args.device,
            pdf_dpi=args.pdf_dpi,
            keep_pdf_images=args.keep_pdf_images,
            pdf_image_dirname=args.pdf_image_dirname,
            image_exts=image_exts,
            pdf_exts=pdf_exts,
        ):
            succeeded_modes.append(MODE_STRUCTURE)
        else:
            failed_modes.append(MODE_STRUCTURE)

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
