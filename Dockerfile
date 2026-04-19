# syntax=docker/dockerfile:1
FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

WORKDIR /app

# 1. Install core system dependencies, downloaders, and Python venv capabilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git libgomp1 tini ffmpeg libgl1 libglib2.0-0 aria2 curl python3-venv \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Binary Applications (FileBrowser, Code-Server, Ollama Daemon)
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash && \
    curl -fsSL https://code-server.dev/install.sh | sh && \
    curl -fsSL https://ollama.com/install.sh | sh

# 3. Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git .

# 4. Install Global Core Dependencies (Added TensorBoard for tracking)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir Cython && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir ninja packaging wheel triton gradio requests tensorboard \
    "accelerate>=1.1.1" "diffusers>=0.31.0" "transformers>=4.39.3" \
    insightface onnxruntime-gpu bitsandbytes huggingface_hub[hf_transfer]

ENV HF_HUB_ENABLE_HF_TRANSFER=1

# 5. Install Performance Extensions (Flash/Sage Attention optimized for 5090)
RUN pip install --no-cache-dir https://huggingface.co/strangertoolshf/flash_attention_2_wheelhouse/resolve/main/wheelhouse-flash_attn-2.8.3/linux_x86_64/torch2.8/cu12/abiFALSE/cp312/flash_attn-2.8.3+cu12torch2.8cxx11abiFALSE-cp312-cp312-linux_x86_64.whl
RUN pip install --no-cache-dir https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl

# 6. Clone Custom Nodes (Including Ollama integration and Florence2 for auto-captioning!)
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
    
# 7. THE SHIELD: Safely install custom node requirements without breaking PyTorch 2.8!
RUN for dir in /app/custom_nodes/*/ ; do \
        if [ -f "$dir/requirements.txt" ]; then \
            sed -i -E '/^(torch|torchvision|torchaudio|xformers)([^a-zA-Z0-9]|$)/d' "$dir/requirements.txt"; \
            pip install --no-cache-dir -r "$dir/requirements.txt"; \
        fi; \
    done

# 8. THE QUARANTINE ZONES: Install heavy apps in isolated environments
WORKDIR /app
# Langflow
RUN python3 -m venv /app/venv_langflow && \
    /app/venv_langflow/bin/pip install --no-cache-dir langflow
# OpenWebUI
RUN python3 -m venv /app/venv_openwebui && \
    /app/venv_openwebui/bin/pip install --no-cache-dir open-webui
# Kohya_ss (Using system-site-packages to safely borrow Torch without breaking it)
RUN git clone --depth 1 https://github.com/bmaltais/kohya_ss.git /app/kohya_ss && \
    python3 -m venv --system-site-packages /app/venv_kohya && \
    sed -i -E '/^(torch|torchvision|torchaudio|xformers)([^a-zA-Z0-9]|$)/d' /app/kohya_ss/requirements_linux.txt && \
    /app/venv_kohya/bin/pip install -r /app/kohya_ss/requirements_linux.txt

# 9. Final execution setup
COPY sidecar.py /app/sidecar.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Open ALL the ports
EXPOSE 8188 8080 8081 7860 8082 8083 28000 6006

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]