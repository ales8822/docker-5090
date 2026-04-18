# syntax=docker/dockerfile:1

FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install system dependencies (Added python3-venv for isolated app bubbles)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libgomp1 \
    tini \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    aria2 \
    curl \
    python3-venv \
    && curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
    && dpkg -i cloudflared.deb \
    && rm cloudflared.deb \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 3. Install core dependencies, HuggingFace Transfer, and GRADIO for the sidecar
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir Cython && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton gradio requests \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3" \
    insightface onnxruntime-gpu bitsandbytes huggingface_hub[hf_transfer]

ENV HF_HUB_ENABLE_HF_TRANSFER=1

# 4. Install Performance Extensions
RUN pip install --no-cache-dir https://huggingface.co/strangertoolshf/flash_attention_2_wheelhouse/resolve/main/wheelhouse-flash_attn-2.8.3/linux_x86_64/torch2.8/cu12/abiFALSE/cp312/flash_attn-2.8.3+cu12torch2.8cxx11abiFALSE-cp312-cp312-linux_x86_64.whl
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

# 5. Clone Custom Nodes
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

# 6. Auto-install Custom Node Requirements
RUN for dir in /app/custom_nodes/*/ ; do \
        if [ -f "$dir/requirements.txt" ]; then \
            pip install --no-cache-dir -r "$dir/requirements.txt"; \
        fi; \
    done

# 8. Install Ollama Core Binary
RUN curl -fsSL https://ollama.com/install.sh | sh

# 9. Install Open WebUI & Langflow in STRICTLY ISOLATED environments
# This prevents them from destroying ComfyUI's fragile PyTorch dependencies.
RUN python3 -m venv /app/venv_openwebui && \
    /app/venv_openwebui/bin/pip install --no-cache-dir --upgrade pip && \
    /app/venv_openwebui/bin/pip install --no-cache-dir open-webui

RUN python3 -m venv /app/venv_langflow && \
    /app/venv_langflow/bin/pip install --no-cache-dir --upgrade pip && \
    /app/venv_langflow/bin/pip install --no-cache-dir langflow

# 10. Reset directory and copy Sidecar
WORKDIR /app
COPY sidecar.py /app/sidecar.py
COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

# EXPOSE NEW PORTS: Comfy(8188), Sidecar(8080), OpenWebUI(8081), Langflow(7860)
EXPOSE 8188 8080 8081 7860

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]