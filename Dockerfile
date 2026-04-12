# syntax=docker/dockerfile:1

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

# 3. Install core dependencies, build tools, and SageAttention prerequisites
# (Added accelerate, diffusers, and transformers requirements based on the guide)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3"

# 4. Install Performance Extensions INSTANTLY (Bypassing 2-hour compile!)
# Ubuntu 24.04 uses Python 3.12, so we use Kijai's precompiled cp312 Linux wheels.
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/flash_attn-2.7.4.post1-cp312-cp312-linux_x86_64.whl
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--highvram"]