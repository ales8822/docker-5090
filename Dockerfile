# syntax=docker/dockerfile:1

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies
# FIX: Added `tini` so your ENTRYPOINT works and doesn't crash the container instantly.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    tini \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI directly into the working directory
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies and build tools
# FIX: Added `ninja`, `packaging`, `wheel`, and `triton`. 
# These are strictly required for `--no-build-isolation` to function properly.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton

# 4. Performance optimization for 5090 (Blackwell)
ENV TORCH_CUDA_ARCH_LIST="9.0;10.0+PTX"
ENV FORCE_CUDA=1
# FIX: Lowered MAX_JOBS to 1 to prevent GitHub Actions runner from crashing (OOM Kill).
ENV MAX_JOBS=1

# 5. Install performance extensions
# FIX: Split these into two separate RUN commands so Docker caches them sequentially.
RUN pip install --no-build-isolation --no-cache-dir git+https://github.com/Dao-AILab/flash-attention.git
RUN pip install --no-build-isolation --no-cache-dir git+https://github.com/thu-ml/SageAttention.git

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
# FIX: explicitly telling ComfyUI to listen on 0.0.0.0 so the Web UI is accessible outside the Docker container
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--highvram"]