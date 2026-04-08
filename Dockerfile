# syntax=docker/dockerfile:1

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI directly into the working directory
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies from the cloned file
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# 4. Performance optimization for 5090
ENV TORCH_CUDA_ARCH_LIST="9.0;10.0+PTX"
ENV FORCE_CUDA=1
ENV MAX_JOBS=4

# 5. Install performance extensions
RUN pip install --no-build-isolation --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py", "--listen", "--port", "8188", "--highvram"]