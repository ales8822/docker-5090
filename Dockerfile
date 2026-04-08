# =================================================================================================
# Stage 1: Wheel Builder - The Foundry
# This stage's ONLY job is to compile all Python dependencies into wheels.
# It contains all the heavy build tools (compilers, headers) that we will discard later.
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /wheels

# Install all necessary build-time dependencies for Python C++/CUDA extensions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    python3.11-dev \
    python3-pip \
    python3.11-venv && \
    rm -rf /var/lib/apt/lists/*

# Create a temporary virtual environment
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Upgrade pip and install the 'wheel' package itself
RUN pip install --no-cache-dir --upgrade pip wheel

# --- Compile All Dependencies into Wheels ---
# We clone ComfyUI here just to get its requirements.txt file.
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /tmp/ComfyUI

# This is the key command. `pip wheel` downloads and builds all packages and their
# dependencies into .whl files in the current directory (`/wheels`).
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r /tmp/ComfyUI/requirements.txt \
    torch torchvision torchaudio xformers triton

# 2. Install performance packages directly from GitHub
# We set this env var to speed up FlashAttention build
ENV FLASH_ATTENTION_FORCE_BUILD=TRUE
RUN pip install --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git

# =================================================================================================
# Stage 2: App Builder - The Assembly Line
# This stage uses the pre-built wheels for a fast and clean installation.
# It then adds the application code and AI models.
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app

# Install runtime dependencies and Python
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    aria2 \
    python3.11 \
    python3.11-venv \
    python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Create the final virtual environment
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy the pre-compiled wheels from the first stage
COPY --from=wheel-builder /wheels /wheels

# --- Install from Local Wheels ---
# --no-index: Prevents pip from searching on PyPI.
# --find-links /wheels: Tells pip to ONLY look in our local /wheels directory.
# This is extremely fast as there's no downloading or compiling.
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r /tmp/ComfyUI/requirements.txt \
    torch torchvision torchaudio xformers triton sage_attn flash-attn

# --- Get ComfyUI and Models ---
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git .
RUN aria2c -x 16 -s 16 -k 1M -d /app/models/checkpoints -o sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors
RUN aria2c -x 16 -s 16 -k 1M -d /app/models/vae -o sdxl_vae.safetensors https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# =================================================================================================
# Stage 3: Final Image - The Spaceship
# This is the lean, optimized final image. We only copy the necessary, pre-built application.
# It contains NO build tools, compilers, or temporary files.
# =================================================================================================
FROM nvidia/cuda:12.5.0-base-ubuntu22.04

WORKDIR /app

# Set environment variables
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV PATH="/opt/venv/bin:$PATH"

# Install tini, the minimal init system for container stability.
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*

# Copy the fully prepared virtual environment and the application from the app-builder stage
COPY --from=app-builder /opt/venv /opt/venv
COPY --from=app-builder /app /app

# Expose the ComfyUI port
EXPOSE 8188

# Use tini to launch ComfyUI for proper signal handling
ENTRYPOINT ["/usr/bin/tini", "--"]

# The command to run, optimized for a high-VRAM GPU like the RTX 5090
CMD ["python3", "main.py", "--listen", "--port", "8188", "--highvram"]
