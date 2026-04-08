# syntax=docker/dockerfile:1

# =========================
# Stage 1: Wheel Builder
# =========================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder
WORKDIR /build

# Install dependencies including python3.11
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3.11 \
    python3.11-venv \
    python3-pip \
    curl \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Add deadsnakes PPA for python3.11 and its dependencies
RUN add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    python3.11-distutils \
    && rm -rf /var/lib/apt/lists/*

# Clone ComfyUI
ARG COMFYUI_COMMIT=HEAD
RUN git clone https://github.com/comfyanonymous/ComfyUI.git \
    && cd ComfyUI \
    && git checkout $COMFYUI_COMMIT

# Set up temporary Python virtualenv for building
RUN python3.11 -m venv /tmp/venv \
    && /tmp/venv/bin/python -m ensurepip \
    && /tmp/venv/bin/python -m pip install --upgrade pip wheel setuptools

# Build heavy wheels (cached)
RUN --mount=type=cache,target=/root/.cache/pip \
    /tmp/venv/bin/python -m pip wheel --wheel-dir=/wheels \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121

# Download all dependencies
RUN --mount=type=cache,target=/root/.cache/pip \
    /tmp/venv/bin/python -m pip download \
    --dest=/wheels \
    -r ComfyUI/requirements.txt

# =========================
# Stage 2: App Builder
# =========================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder
WORKDIR /app

# Install Python, git, and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3-pip \
    git \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/* \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends python3.11-distutils \
    && rm -rf /var/lib/apt/lists/*

# Create clean venv
RUN python3.11 -m venv /opt/venv \
    && /opt/venv/bin/python -m ensurepip \
    && /opt/venv/bin/python -m pip install --upgrade pip

# Copy wheels from Stage 1
COPY --from=wheel-builder /wheels /wheels

# Copy ComfyUI source from Stage 1
COPY --from=wheel-builder /build/ComfyUI /app

# Install all dependencies using the wheels and resolver
RUN /opt/venv/bin/python -m pip install \
    --no-index --find-links=/wheels \
    -r requirements.txt \
    && rm -rf /app/.git

# Environment variables for performance tuning
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
    git+https://github.com/thu-ml/SageAttention.git \
    --no-cache-dir \
    && rm -rf /root/.cache/pip

# =========================
# Stage 3: Runtime
# =========================
FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04
WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    software-properties-common \
    tini \
    && rm -rf /var/lib/apt/lists/* \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends python3.11-distutils \
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