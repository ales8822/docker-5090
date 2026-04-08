# syntax=docker/dockerfile:1.7-labs

# =================================================================================================
# Stage 1: Build wheels (portable)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3.11 python3.11-venv python3-pip build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create temp venv JUST for building
RUN python3.11 -m venv /tmp/venv && \
    /tmp/venv/bin/python -m ensurepip && \
    /tmp/venv/bin/python -m pip install --upgrade pip wheel setuptools

ENV PATH="/tmp/venv/bin:$PATH"

# Clone repo
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git

# Build heavy wheels
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip wheel --wheel-dir=/wheels \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# Download rest
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip download \
    --dest=/wheels \
    -r ComfyUI/requirements.txt \
    --no-deps \
    --only-binary=:all: || true


# =================================================================================================
# Stage 2: Build app (FRESH venv = no breakage)
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ✅ CREATE NEW CLEAN VENV (this fixes everything)
RUN python3.11 -m venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip && \
    /opt/venv/bin/python -m pip install --upgrade pip

# Copy wheels + app
COPY --from=wheel-builder /wheels /wheels
COPY --from=wheel-builder /build/ComfyUI /app

# Install deps from wheels
RUN /opt/venv/bin/python -m pip install \
    --no-index --find-links=/wheels /wheels/*

RUN /opt/venv/bin/python -m pip install -r requirements.txt

# RTX 5090 tuning
ENV TORCH_CUDA_ARCH_LIST="10.0+PTX" \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1

RUN /opt/venv/bin/python -m pip install \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git


# =================================================================================================
# Stage 3: Runtime
# =================================================================================================
FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=app-builder /opt/venv /opt/venv
COPY --from=app-builder /app /app

ENV PATH="/opt/venv/bin:$PATH" \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    CUDA_MODULE_LOADING=LAZY

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/venv/bin/python", "main.py", "--listen", "--port", "8188", "--highvram"]
