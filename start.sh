#!/bin/bash
echo "Starting Gradio Sidecar on port 8080..."
python /app/sidecar.py &

echo "Starting ComfyUI on port 8188..."
python /app/main.py --listen 0.0.0.0 --port 8188 --highvram