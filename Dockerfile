# syntax=docker/dockerfile:1.7-labs
# =================================================================================================
# Stage 1: Wheel Builder (heaviest step, aggressively cached)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /build

# ---- System deps (rarely change → strong cache layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3.11 python3.11-venv python3-pip build-essential \
    && rm -rf /var/lib/apt/lists/*

# ---- Virtualenv
RUN python3.11 -m venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip && \
    /opt/venv/bin/pip install --upgrade pip wheel setuptools
ENV PATH="/opt/venv/bin:$PATH"

# ---- Speed up pip (critical for rebuild speed)
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=100

RUN pip install --upgrade pip wheel setuptools

# ---- Clone ComfyUI (cache bust only when repo changes)
ARG COMFYUI_COMMIT=HEAD
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd ComfyUI && git checkout $COMFYUI_COMMIT

# ---- Build heavy GPU wheels (MOST IMPORTANT LAYER)
# Cached unless you change CUDA / torch version
RUN --mount=type=cache,target=/root/.cache/pip \
    pip wheel --wheel-dir=/wheels \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# ---- Pre-download remaining deps (fast layer)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip download --dest=/wheels \
    -r ComfyUI/requirements.txt \
    --no-deps \
    --only-binary=:all: || true


# =================================================================================================
# Stage 2: App Builder (fast, incremental)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app

# ---- Reuse venv (contains pip + base tooling)
COPY --from=wheel-builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# ---- Copy wheels FIRST (better cache reuse)
COPY --from=wheel-builder /wheels /wheels

# ---- Install heavy deps FIRST (rarely change)
RUN /opt/venv/bin/pip install --no-index --find-links=/wheels /wheels/*

# ---- Copy app AFTER deps (prevents reinstalling deps on code change)
COPY --from=wheel-builder /build/ComfyUI /app

# ---- Install remaining deps (very fast now)
RUN pip install -r requirements.txt

# ---- RTX 5090 tuning (Blackwell)
ENV TORCH_CUDA_ARCH_LIST="10.0+PTX" \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1

# ---- Flash + Sage (compiled with correct arch)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git


# =================================================================================================
# Stage 3: Runtime (lean)
# =================================================================================================
FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04

WORKDIR /app

# Minimal runtime deps only
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 tini \
    && rm -rf /var/lib/apt/lists/*

# Copy runtime
COPY --from=app-builder /opt/venv /opt/venv
COPY --from=app-builder /app /app

ENV PATH="/opt/venv/bin:$PATH"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# ---- Runtime performance tweaks (important)
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    CUDA_MODULE_LOADING=LAZY \
    TORCH_ALLOW_TF32_CUBLAS_OVERRIDE=1

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["python", "main.py", "--listen", "--port", "8188", "--highvram"]
