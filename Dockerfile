# syntax=docker/dockerfile:1

# We are keeping Torch 2.8.0! This is strictly required for the RTX 5090 (Blackwell sm_120)
FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    tini \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI directly into the working directory
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies (Notice: We removed the PyTorch downgrade!)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3"

# 4. Install Performance Extensions via Precompiled Wheels
# FIX: Using a highly specific Flash Attention wheel built explicitly for PyTorch 2.8.0
RUN pip install --no-cache-dir https://huggingface.co/strangertoolshf/flash_attention_2_wheelhouse/resolve/main/wheelhouse-flash_attn-2.8.3/linux_x86_64/torch2.8/cu12/abiFALSE/cp312/flash_attn-2.8.3+cu12torch2.8cxx11abiFALSE-cp312-cp312-linux_x86_64.whl
# Kijai's SageAttention wheel remains, as it safely supports Torch 2.8.0
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--highvram"]