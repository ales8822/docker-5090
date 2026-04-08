# syntax=docker/dockerfile:1.7-labs

# =================================================================================================
# Stage 1: Wheel Builder (portable artifacts only)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /build

# System deps (stable layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3.11 python3.11-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Temp venv ONLY for building wheels
RUN python3.11 -m venv /tmp/venv && \
    /tmp/venv/bin/python -m ensurepip && \
    /tmp/venv/bin/python -m pip install --upgrade pip wheel setuptools

ENV PATH="/tmp/venv/bin:$PATH"

# Clone ComfyUI
ARG COMFYUI_COMMIT=HEAD
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd ComfyUI && git checkout $COMFYUI_COMMIT

# Build heavy wheels (cached)
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip wheel --wheel-dir=/wheels \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# Download ALL dependencies (IMPORTANT: no --no-deps)
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip download \
    --dest=/wheels \
    -r ComfyUI/requirements.txt


# =================================================================================================
# Stage 2: App Builder (fresh venv, deterministic install)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app

# Install Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Create CLEAN venv (never copied)
RUN python3.11 -m venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip && \
    /opt/venv/bin/python -m pip install --upgrade pip

# Copy wheels + app
COPY --from=wheel-builder /wheels /wheels
COPY --from=wheel-builder /build/ComfyUI /app

# Install using resolver (CORRECT way)
RUN /opt/venv/bin/python -m pip install \
    --no-index --find-links=/wheels \
    -r requirements.txt

# RTX 5090 tuning
ENV TORCH_CUDA_ARCH_LIST="10.0+PTX" \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1 \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    CUDA_MODULE_LOADING=LAZY \
    TORCH_ALLOW_TF32_CUBLAS_OVERRIDE=1

# Install performance extensions
RUN --mount=type=cache,target=/root/.cache/pip \
    /opt/venv/bin/python -m pip install \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git


# =================================================================================================
# Stage 3: Runtime (minimal + stable)
# =================================================================================================
FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 tini \
    && rm -rf /var/lib/apt/lists/*

# Copy final artifacts
COPY --from=app-builder /opt/venv /opt/venv
COPY --from=app-builder /app /app

ENV PATH="/opt/venv/bin:$PATH" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/opt/venv/bin/python", "main.py", "--listen", "--port", "8188", "--highvram"]
