# syntax=docker/dockerfile:1

# Switched to CUDA 12.4 and PyTorch 2.6.0 for maximum Community Node compatibility
FROM runpod/pytorch:1.0.2-cu124-torch260-ubuntu2404

WORKDIR /app

# 1. Install core system dependencies, downloaders, and Python venv capabilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git libgomp1 tini ffmpeg libgl1 libglib2.0-0 aria2 curl python3-venv python3-tk \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Binary Applications (FileBrowser, Code-Server, Ollama Daemon)
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash && \
    curl -fsSL https://code-server.dev/install.sh | sh && \
    curl -fsSL https://ollama.com/install.sh | sh

# 3. Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 4. Install Global Core Dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir Cython && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton gradio requests tensorboard \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3" \
    insightface onnxruntime-gpu bitsandbytes huggingface_hub[hf_transfer]

ENV HF_HUB_ENABLE_HF_TRANSFER=1

# 5. Install Performance Extensions (Switched to Kijai's PyTorch 2.6 Flash Attention Wheel)
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/flash_attn-2.7.4.post1-cp312-cp312-linux_x86_64.whl
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

# 6. Clone Custom Nodes
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
    git clone https://github.com/11cafe/comfyui-workspace-manager.git && \
    git clone https://github.com/stavsap/comfyui-ollama.git && \
    git clone https://github.com/kijai/ComfyUI-Florence2.git

# 7. THE SHIELD
RUN for dir in /app/custom_nodes/*/ ; do \
        if [ -f "$dir/requirements.txt" ]; then \
            sed -i -E '/^(torch|torchvision|torchaudio|xformers)([^a-zA-Z0-9]|$)/d' "$dir/requirements.txt"; \
            pip install --no-cache-dir -r "$dir/requirements.txt"; \
        fi; \
    done

# 8. THE QUARANTINE ZONES
WORKDIR /app
RUN python3 -m venv /app/venv_langflow && \
    /app/venv_langflow/bin/pip install --no-cache-dir langflow

RUN python3 -m venv /app/venv_openwebui && \
    /app/venv_openwebui/bin/pip install --no-cache-dir open-webui

RUN git clone --recursive https://github.com/bmaltais/kohya_ss.git /app/kohya_ss && \
    python3 -m venv --system-site-packages /app/venv_kohya && \
    cd /app/kohya_ss && \
    sed -i -E '/^(torch|torchvision|torchaudio|xformers)([^a-zA-Z0-9]|$)/d' requirements_linux.txt requirements.txt && \
    sed -i -E 's/^(tensorflow|tensorboard)[^a-zA-Z0-9].*/\1/g' requirements_linux.txt requirements.txt && \
    /app/venv_kohya/bin/pip install -r requirements_linux.txt

# 9. Final execution setup
COPY sidecar.py /app/sidecar.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

EXPOSE 8188 8080 8081 7860 8082 8083 28000 6006

ENTRYPOINT["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]