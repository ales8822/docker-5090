# =================================================================================================
# Stage 1: Wheel Builder
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS wheel-builder

WORKDIR /wheels

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git python3.11-dev python3-pip python3.11-venv && \
    rm -rf /var/lib/apt/lists/*

RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip wheel

# Clone ComfyUI to get requirements.txt
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /tmp/ComfyUI

# CRITICAL: Use `pip wheel` to DOWNLOAD and COMPILE into the /wheels folder
RUN pip wheel --wheel-dir=/wheels \
    -r /tmp/ComfyUI/requirements.txt \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 \
    xformers triton

# =================================================================================================
# Stage 2: App Builder
# =================================================================================================
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS app-builder

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    git aria2 python3.11 python3.11-venv python3-pip && \
    rm -rf /var/lib/apt/lists/*

RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy the PRE-FILLED /wheels folder from the first stage
COPY --from=wheel-builder /wheels /wheels

# NOW you can install from the populated /wheels directory
RUN pip install --no-index --find-links=/wheels /wheels/*.whl

# Install Performance packages from Source
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 10.0"
RUN pip install --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git

# Clone ComfyUI and download models
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git .
# ... (rest of your model download steps)

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
