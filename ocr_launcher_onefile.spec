# -*- mode: python ; coding: utf-8 -*-

import os
import importlib.util
from pathlib import Path

from PyInstaller.utils.hooks import collect_all, copy_metadata


def unique_entries(entries):
    seen = set()
    out = []
    for entry in entries:
        if entry in seen:
            continue
        seen.add(entry)
        out.append(entry)
    return out


project_root = Path(os.environ.get("PADDLE_OCR_PROJECT_ROOT", Path.cwd())).resolve()
bundle_name = os.environ.get("PADDLE_OCR_BUNDLE_NAME", "PaddleOCRLauncher")
include_model_cache = os.environ.get("PADDLE_OCR_INCLUDE_MODEL_CACHE", "0") == "1"

packages_to_collect = [
    "paddleocr",
    "paddlex",
    "paddle",
    "fitz",
    "chardet",
    "charset_normalizer",
    "pymupdf",
    "pyclipper",
    "shapely",
    "pypdfium2",
    "yaml",
    "ruamel.yaml",
    "tokenizers",
    "safetensors",
    "sentencepiece",
    "huggingface_hub",
    "modelscope",
    "aistudio_sdk",
    "pydantic",
    "pydantic_core",
]

nvidia_runtime_packages = [
    "nvidia.cublas",
    "nvidia.cuda_nvrtc",
    "nvidia.cuda_runtime",
    "nvidia.cudnn",
    "nvidia.cufft",
    "nvidia.curand",
    "nvidia.cusolver",
    "nvidia.cusparse",
]

datas = []
binaries = []
hiddenimports = []
hiddenimports.extend(
    [
        "0deeb2fec52624e647be__mypyc",
        "81d243bd2c585b0f4821__mypyc",
    ]
)

for package_name in packages_to_collect:
    try:
        pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(
            package_name,
            include_py_files=True,
        )
        datas.extend(pkg_datas)
        binaries.extend(pkg_binaries)
        hiddenimports.extend(pkg_hiddenimports)
    except Exception as exc:
        print(f"[spec] Warning: collect_all({package_name}) failed: {exc}")

for metadata_name in ["paddlex", "paddleocr", "chardet", "charset-normalizer", "requests"]:
    try:
        datas.extend(copy_metadata(metadata_name))
    except Exception as exc:
        print(f"[spec] Warning: copy_metadata({metadata_name}) failed: {exc}")

for package_name in nvidia_runtime_packages:
    try:
        spec = importlib.util.find_spec(package_name)
        if spec is None or not spec.submodule_search_locations:
            print(f"[spec] Warning: runtime package not found: {package_name}")
            continue

        package_root = Path(next(iter(spec.submodule_search_locations))).resolve()
        bin_dir = package_root / "bin"
        if not bin_dir.is_dir():
            print(f"[spec] Warning: runtime bin dir not found: {bin_dir}")
            continue

        target_dir = f"nvidia/{package_root.name}/bin"
        for dll_path in bin_dir.glob("*.dll"):
            binaries.append((str(dll_path), target_dir))
    except Exception as exc:
        print(f"[spec] Warning: collect NVIDIA runtime for {package_name} failed: {exc}")

if include_model_cache:
    model_cache_root = Path.home() / ".paddlex" / "official_models"
    if model_cache_root.is_dir():
        datas.append((str(model_cache_root), "bundled_model_cache/official_models"))
    else:
        print(f"[spec] Warning: bundled model cache was requested but not found: {model_cache_root}")

datas = unique_entries(datas)
binaries = unique_entries(binaries)
hiddenimports = sorted(set(hiddenimports))


a = Analysis(
    [str(project_root / "run_ocr_launcher.py")],
    pathex=[str(project_root)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name=bundle_name,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
)
