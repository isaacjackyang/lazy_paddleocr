FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True \
    PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=False \
    OMP_NUM_THREADS=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libgl1 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel

RUN python -m pip install --no-cache-dir \
    paddlepaddle==3.2.2 \
    paddleocr==3.7.0 \
    "paddlex[ocr]==3.7.0" \
    onnxruntime \
    pillow \
    pymupdf

WORKDIR /workspace

CMD ["python", "tools/run_ocr_launcher.py", "--recursive"]
