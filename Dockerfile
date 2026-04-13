# syntax=docker/dockerfile:1

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    tini \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies & THE "NIGHTMARE" LIBRARIES
# Added Cython, insightface, onnxruntime-gpu, and bitsandbytes
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir Cython && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3" \
    insightface onnxruntime-gpu bitsandbytes

# 4. Install Performance Extensions (Flash Attention & Sage Attention)
RUN pip install --no-cache-dir https://huggingface.co/strangertoolshf/flash_attention_2_wheelhouse/resolve/main/wheelhouse-flash_attn-2.8.3/linux_x86_64/torch2.8/cu12/abiFALSE/cp312/flash_attn-2.8.3+cu12torch2.8cxx11abiFALSE-cp312-cp312-linux_x86_64.whl
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

# 5. Clone ComfyUI Manager and the Most Popular Custom Nodes
WORKDIR /app/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone https://github.com/civitai/civitai_comfy_nodes.git && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone https://github.com/rgthree/rgthree-comfy.git && \
    git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git && \
    git clone https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git && \
    git clone https://github.com/city96/ComfyUI-GGUF.git && \
    git clone https://github.com/11cafe/comfyui-workspace-manager.git

# 6. Automatically install all Python dependencies for the downloaded nodes
RUN for dir in /app/custom_nodes/*/ ; do \
        if [ -f "$dir/requirements.txt" ]; then \
            pip install --no-cache-dir -r "$dir/requirements.txt"; \
        fi; \
    done

# 7. Reset working directory back to ComfyUI root
WORKDIR /app

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--highvram"]