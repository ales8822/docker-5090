# =================================================================================================
# Stage 1: Wheel Builder
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /wheels

RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3.11-venv python3-pip && rm -rf /var/lib/apt/lists/*

RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip wheel

# Clone ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /tmp/ComfyUI

# STEP 1: Build the big heavy dependencies (Torch/Triton) into wheels
# We explicitly call out the packages we want to wheel.
RUN pip wheel --wheel-dir=/wheels \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# STEP 2: Download the remaining standard requirements from requirements.txt
# We ignore the ones that aren't on PyPI (like frontend packages)
RUN pip download --dest=/wheels \
    -r /tmp/ComfyUI/requirements.txt \
    --index-url https://pypi.org/simple \
    --no-deps \
    --ignore-requires-python \
    --only-binary=:all: 2>/dev/null || true

# =================================================================================================
# Stage 2: App Builder
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder
WORKDIR /app
# ... (standard setup) ...

# 1. Install the wheels we just built
COPY --from=wheel-builder /wheels /wheels
RUN pip install --no-index --find-links=/wheels /wheels/*.whl

# 2. Install the full requirements file normally 
# Because the heavy stuff (torch/xformers) is already installed, 
# this will just "see" them and skip to installing the rest.
COPY --from=wheel-builder /tmp/ComfyUI /app
RUN pip install -r requirements.txt

# 3. Install your performance packages (Sage/Flash)
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 10.0"
RUN pip install --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git
# Clone ComfyUI and download models
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git .

# =================================================================================================
# Stage 3: Final Image
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
