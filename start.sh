#!/bin/bash
# 1. Start FileBrowser directly into /app (Port 8083)
echo "Starting FileBrowser on port 8083..."
filebrowser -r /app -a 0.0.0.0 -p 8083 --noauth &

# 2. Start the Sidecar Manager (Port 8080)
echo "Starting Gradio Sidecar on port 8080..."
python /app/sidecar.py &

# 3. Start ComfyUI (Port 8188) -> Foreground process to keep container alive
echo "Starting ComfyUI on port 8188..."
python /app/main.py --listen 0.0.0.0 --port 8188 --highvram