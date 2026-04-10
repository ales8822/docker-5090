# syntax=docker/dockerfile:1

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies (Added 'tini' to prevent container crash)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    tini \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI directly into the working directory
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies and missing build tools
# Added ninja, packaging, wheel, and triton (required by SageAttention)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton

# 4. Performance optimization for RTX 5090 (Blackwell) & RTX 4090 (Ada)
ENV TORCH_CUDA_ARCH_LIST="8.9;9.0;10.0+PTX"
ENV FORCE_CUDA=1
# MAX_JOBS=1 strictly limits compiler threads so GitHub Actions does not run out of RAM
ENV MAX_JOBS=1

# 5. Install performance extensions (Split into two steps so Docker caches them separately)
RUN pip install --no-build-isolation --no-cache-dir git+https://github.com/Dao-AILab/flash-attention.git
RUN pip install --no-build-isolation --no-cache-dir git+https://github.com/thu-ml/SageAttention.git

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
# Changed to listen on 0.0.0.0 so the Web UI is accessible outside the RunPod container
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--highvram"]