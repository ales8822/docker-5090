# syntax=docker/dockerfile:1.7-labs

# =================================================================================================
# Stage 1: Wheel Builder (heavy + cached)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /build

# ---- System dependencies (stable layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3.11 python3.11-venv python3-pip build-essential \
    && rm -rf /var/lib/apt/lists/*

# ---- Create HARDENED virtualenv (pip guaranteed)
RUN python3.11 -m venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip --upgrade && \
    /opt/venv/bin/python -m pip install --upgrade pip setuptools wheel

# ---- pip environment tuning
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=100

# ---- Clone ComfyUI (cache-controlled)
ARG COMFYUI_COMMIT=HEAD
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd ComfyUI && git checkout $COMFYUI_COMMIT

# ---- Build heavy wheels (MOST EXPENSIVE → cached)
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/python -m pip wheel \
    --wheel-dir=/wheels \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# ---- Download remaining deps (fast)
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/python -m pip download \
    --dest=/wheels \
    -r ComfyUI/requirements.txt \
    --no-deps \
    --only-binary=:all: || true


# =================================================================================================
# Stage 2: App Builder (deterministic + fast)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app

# ---- Copy hardened venv
COPY --from=wheel-builder /opt/venv /opt/venv

# ---- Copy wheels FIRST (better caching)
COPY --from=wheel-builder /wheels /wheels

# ---- Install heavy deps (rarely changes)
RUN /opt/venv/bin/python -m pip install \
    --no-index --find-links=/wheels /wheels/*

# ---- Copy app AFTER deps (prevents reinstall)
COPY --from=wheel-builder /build/ComfyUI /app

# ---- Install remaining deps (fast)
RUN /opt/venv/bin/python -m pip install -r requirements.txt

# ---- RTX 5090 / Blackwell tuning
ENV TORCH_CUDA_ARCH_LIST="10.0+PTX" \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1 \
    MAX_JOBS=8

# ---- Compile performance extensions
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/python -m pip install --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git


# =================================================================================================
# Stage 3: Runtime (lean + stable)
# =================================================================================================
FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04

WORKDIR /app

# ---- Minimal runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 tini \
    && rm -rf /var/lib/apt/lists/*

# ---- Copy runtime artifacts
COPY --from=app-builder /opt/venv /opt/venv
COPY --from=app-builder /app /app

# ---- Runtime environment
ENV PATH="/opt/venv/bin:$PATH" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    CUDA_MODULE_LOADING=LAZY \
    TORCH_ALLOW_TF32_CUBLAS_OVERRIDE=1

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/opt/venv/bin/python", "main.py", "--listen", "--port", "8188", "--highvram"]
