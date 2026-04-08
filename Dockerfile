# syntax=docker/dockerfile:1

# Inherit from the specific RunPod PyTorch base image
FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

# Set up work directory
WORKDIR /app

# Install build dependencies for custom extensions (Flash/SageAttention)
# 'libgomp1' is necessary for performance extensions to execute correctly
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Copy ComfyUI requirements first to leverage Docker layer caching
# You must have a local requirements.txt in your repo root
COPY requirements.txt .

# Upgrade pip and install core dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Performance optimization: Force kernel compilation for Blackwell (5090)
ENV TORCH_CUDA_ARCH_LIST="9.0;10.0+PTX"
ENV FORCE_CUDA=1
ENV MAX_JOBS=4

# Install performance extensions with no-build-isolation to ensure they 
# compile against the pre-installed PyTorch in the RunPod image
RUN pip install --no-build-isolation --no-cache-dir \
    git+https://github.com/Dao-AILab/flash-attention.git \
    git+https://github.com/thu-ml/SageAttention.git

# Copy the rest of the application
COPY . .

# Ensure standard ComfyUI ports and signals
EXPOSE 8188

# Entrypoint for clean shutdowns
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py", "--listen", "--port", "8188", "--highvram"]