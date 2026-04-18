import gradio as gr
import os, subprocess, re, requests, shutil, json
from urllib.parse import urlparse

# --- CORRECTED PATHS FOR DOCKER ---
COMFY_ROOT = "/app"
COMFY_OUTPUT = os.path.join(COMFY_ROOT, "output")
HISTORY_FILE = "/app/sidecar_history.json"
TOKENS_FILE = "/app/tokens.txt"
VENV_PIP = "pip" # We use global pip in the Docker container

os.makedirs(COMFY_OUTPUT, exist_ok=True)

# --- UTILS & AUTHENTICATION ---
current_process = None
cancel_requested = False

def get_tokens():
    tokens = {
        "HF": os.environ.get("HF_TOKEN"),
        "CIVITAI": os.environ.get("CIVITAI_TOKEN")
    }
    if os.path.exists(TOKENS_FILE):
        with open(TOKENS_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("HF_TOKEN=") and not tokens["HF"]:
                    tokens["HF"] = line.split("=", 1)[1].strip()
                elif line.startswith("CIVITAI_TOKEN=") and not tokens["CIVITAI"]:
                    tokens["CIVITAI"] = line.split("=", 1)[1].strip()
    return tokens

def format_bytes(size_in_bytes):
    if size_in_bytes < 1024**2: return f"{size_in_bytes / 1024:.1f} KB"
    elif size_in_bytes < 1024**3: return f"{size_in_bytes / (1024**2):.1f} MB"
    else: return f"{size_in_bytes / (1024**3):.2f} GB"

def get_dir_size(start_path):
    total_size = 0
    for dirpath, _, filenames in os.walk(start_path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            if not os.path.islink(fp) and os.path.exists(fp):
                total_size += os.path.getsize(fp)
    return total_size

def load_history():
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r") as f: return json.load(f)
        except: pass
    return[]

def save_history(history_list):
    with open(HISTORY_FILE, "w") as f:
        json.dump(history_list, f, indent=4)

def append_history(name, path, is_node, size_str):
    hist = load_history()
    hist = [h for h in hist if h['path'] != path]
    hist.append({"name": name, "path": path, "is_node": is_node, "size": size_str})
    save_history(hist)

# --- GENERATOR LOGIC ---
def request_cancel():
    global cancel_requested, current_process
    cancel_requested = True
    if current_process:
        try: current_process.kill()
        except: pass
    return "⚠️ Cancellation triggered! Killing active network processes..."

def sync_generator(file_path):
    global cancel_requested, current_process
    cancel_requested = False
    current_process = None
    auth_tokens = get_tokens()

    if not file_path:
        yield "❌ Error: No file uploaded.", "No queue", gr.update()
        return

    if hasattr(file_path, "name"): file_path = file_path.name

    with open(file_path, "r") as f:
        lines = f.readlines()

    tasks =[]
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"): continue
        
        url_match = re.match(r"^(https?://\S+)", line)
        if url_match:
            url = url_match.group(1)
            tag_match = re.search(r"\[([^'\]]+)\]", line[len(url):])
            name_match = re.search(r"\['([^']+)'\]", line[len(url):])
            
            tag = tag_match.group(1).strip() if tag_match else "models/checkpoints"
            custom_name = name_match.group(1).strip() if name_match else None

            if "github.com" in url or url.endswith(".git"):
                url = url if url.endswith(".git") else url + ".git"
                tasks.append({"url": url, "tag": "custom_nodes", "custom_name": None, "status": "pending", "size": "", "path": ""})
            else:
                tasks.append({"url": url, "tag": tag, "custom_name": custom_name, "status": "pending", "size": "", "path": ""})

    def render_queue(current_idx=-1):
        q_lines =[]
        for i, t in enumerate(tasks):
            display_name = t['custom_name'] if t['custom_name'] else t['url'].rstrip('/').split('/')[-1].replace('.git', '')
            icon = "⏳"
            if t['status'] == "done": 
                icon = "✅"
                display_name += f"  💾 ({t['size']})"
            elif t['status'] == "error": icon = "❌"
            elif t['status'] == "cancelled": icon = "🛑"
            elif i == current_idx: icon = "▶️"
            q_lines.append(f"{icon} {i+1}. {display_name}")
        return "\n".join(q_lines)

    log_history =[]
    def update_log(msg, replace_last=False):
        if replace_last and log_history and log_history[-1].startswith("   ->"):
            log_history[-1] = f"   -> {msg}"
        else:
            log_history.append(f"   -> {msg}" if replace_last else msg)
        return "\n".join(log_history[-20:])

    if not tasks:
        yield update_log("⚠️ No valid tasks found in text file."), "Empty", gr.update(value=None)
        return

    current_queue_ui = render_queue()
    yield update_log(f"🔍 Found {len(tasks)} tasks. Starting Queue..."), current_queue_ui, gr.update()

    for i, task in enumerate(tasks):
        if cancel_requested: break

        url, tag, custom_name = task["url"], task["tag"], task["custom_name"]
        current_queue_ui = render_queue(i)
        yield update_log(f"\n--- Task {i+1} of {len(tasks)} ---"), current_queue_ui, gr.update()

        if "custom_nodes" in tag or url.endswith(".git"):
            repo_name = url.rstrip('/').split('/')[-1].replace(".git", "")
            target_dir = os.path.join(COMFY_ROOT, "custom_nodes", repo_name)
            
            if not os.path.exists(target_dir):
                yield update_log(f"📦 Cloning Node: {repo_name}..."), current_queue_ui, gr.update()
                try:
                    current_process = subprocess.Popen(["git", "clone", "--depth", "1", url, target_dir], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    current_process.wait()
                    if cancel_requested: 
                        tasks[i]["status"] = "cancelled"
                        continue
                    if current_process.returncode != 0: raise Exception("Git clone failed.")
                    
                    req_file = os.path.join(target_dir, "requirements.txt")
                    if os.path.exists(req_file):
                        yield update_log(f"⚙️ Installing dependencies for {repo_name}..."), current_queue_ui, gr.update()
                        current_process = subprocess.Popen([VENV_PIP, "install", "-r", req_file], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                        current_process.wait()

                    if cancel_requested:
                        tasks[i]["status"] = "cancelled"
                        continue

                    tasks[i]["status"] = "done"
                    folder_size = format_bytes(get_dir_size(target_dir))
                    tasks[i]["size"] = folder_size
                    append_history(repo_name, target_dir, True, folder_size)
                    
                    current_queue_ui = render_queue(i)
                    yield update_log(f"✅ Finished Node: {repo_name}"), current_queue_ui, gr.update()
                except Exception as e:
                    tasks[i]["status"] = "error"
                    current_queue_ui = render_queue(i)
                    yield update_log(f"❌ Error processing {repo_name}: {str(e)}"), current_queue_ui, gr.update()
                finally:
                    current_process = None
            else:
                tasks[i]["status"] = "done"
                folder_size = format_bytes(get_dir_size(target_dir))
                tasks[i]["size"] = folder_size
                current_queue_ui = render_queue(i)
                yield update_log(f"ℹ️ Node {repo_name} already exists. Skipping."), current_queue_ui, gr.update()

        else:
            dest_dir = os.path.join(COMFY_ROOT, tag)
            os.makedirs(dest_dir, exist_ok=True)
            
            file_name = custom_name if custom_name else os.path.basename(urlparse(url).path)
            file_name = file_name.split("?")[0] 
            dest_file = os.path.join(dest_dir, file_name)
            
            yield update_log(f"⏳ Downloading Model: {file_name}..."), current_queue_ui, gr.update()
            
            if "civitai.com" in url:
                try:
                    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
                    if auth_tokens["CIVITAI"] and "token=" not in url:
                        join_char = "&" if "?" in url else "?"
                        url = f"{url}{join_char}token={auth_tokens['CIVITAI']}"

                    response = requests.get(url, stream=True, headers=headers, allow_redirects=True)
                    response.raise_for_status()
                    total_size = int(response.headers.get('content-length', 0))
                    dl_size = 0
                    
                    with open(dest_file, 'wb') as f:
                        for chunk in response.iter_content(chunk_size=1024*1024):
                            if cancel_requested: break
                            if chunk:
                                f.write(chunk)
                                dl_size += len(chunk)
                                if total_size > 0:
                                    pct = int((dl_size / total_size) * 100)
                                    prog_str = f"[{pct}% | {format_bytes(dl_size)} / {format_bytes(total_size)}]"
                                    yield update_log(prog_str, replace_last=True), current_queue_ui, gr.update()
                    
                    if cancel_requested:
                        if os.path.exists(dest_file): os.remove(dest_file)
                        tasks[i]["status"] = "cancelled"
                        continue

                    tasks[i]["status"] = "done"
                    tasks[i]["size"] = format_bytes(os.path.getsize(dest_file))
                    append_history(file_name, dest_file, False, tasks[i]["size"])
                    yield update_log("[100% | Download Complete]", replace_last=True), current_queue_ui, gr.update()
                    yield update_log(f"✅ Successfully downloaded: {file_name}"), current_queue_ui, gr.update()

                except Exception as e:
                    tasks[i]["status"] = "error"
                    current_queue_ui = render_queue(i)
                    yield update_log(f"❌ Download error: {str(e)}"), current_queue_ui, gr.update()
            
            else:
                cmd =["aria2c", "--allow-overwrite=true", "--auto-file-renaming=false",
                       "-x", "16", "-s", "16",
                       "--console-log-level=warn", "--summary-interval=1",
                       "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)"]
                if "huggingface.co" in url and auth_tokens["HF"]:
                    cmd.append(f"--header=Authorization: Bearer {auth_tokens['HF']}")
                cmd.extend(["-d", dest_dir, "-o", file_name, url])
                
                try:
                    current_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    for output in current_process.stdout:
                        if cancel_requested:
                            current_process.kill()
                            break

                        output = output.strip()
                        if not output: continue
                        m = re.search(r"([\d\.]+[KMG]?iB)/([\d\.]+[KMG]?iB)\((\d+)%\)", output)
                        if m:
                            dl, total, pct = m.groups()
                            prog_str = f"[{pct}% | {dl} / {total}]"
                            yield update_log(prog_str, replace_last=True), current_queue_ui, gr.update()
                        elif "error" in output.lower() or "exception" in output.lower():
                            yield update_log(f"⚠️ {output}"), current_queue_ui, gr.update()
                    
                    current_process.wait()
                    if cancel_requested:
                        tasks[i]["status"] = "cancelled"
                        continue
                    
                    if current_process.returncode == 0:
                        tasks[i]["status"] = "done"
                        file_size = format_bytes(os.path.getsize(dest_file))
                        tasks[i]["size"] = file_size
                        append_history(file_name, dest_file, False, file_size)

                        current_queue_ui = render_queue(i)
                        yield update_log("[100% | Download Complete]", replace_last=True), current_queue_ui, gr.update()
                        yield update_log(f"✅ Successfully downloaded: {file_name}"), current_queue_ui, gr.update()
                    else:
                        tasks[i]["status"] = "error"
                        current_queue_ui = render_queue(i)
                        yield update_log(f"❌ Failed downloading: {file_name} (Code {current_process.returncode})"), current_queue_ui, gr.update()
                        
                except Exception as e:
                    tasks[i]["status"] = "error"
                    current_queue_ui = render_queue(i)
                    yield update_log(f"❌ Download error: {str(e)}"), current_queue_ui, gr.update()
                finally:
                    current_process = None

    if cancel_requested:
        yield update_log("\n🛑 PROCESS CANCELLED BY USER."), render_queue(), gr.update(value=None)
        return

    yield update_log("\n🔄 Refreshing ComfyUI Nodes..."), render_queue(), gr.update()
    try:
        requests.post("http://127.0.0.1:8188/api/refresh", timeout=5)
        yield update_log("🚀 ALL TASKS COMPLETE. You can drop another file now!"), render_queue(), gr.update(value=None)
    except Exception as e:
        yield update_log(f"⚠️ ComfyUI is not responding to refresh ({str(e)})."), render_queue(), gr.update(value=None)

def refresh_history_ui():
    hist = load_history()
    choices =[]
    for h in hist:
        if os.path.exists(h['path']):
            tag = "📦 NODE" if h['is_node'] else "🗂️ MODEL"
            choices.append(f"{tag} | {h['name']} ({h['size']}) -> {h['path']}")
    return gr.update(choices=choices)

def delete_selected_files(selected_strings):
    if not selected_strings: return "⚠️ No files selected.", refresh_history_ui()
    log, hist =[], load_history()
    for item in selected_strings:
        target_path = item.split(" -> ")[-1].strip()
        if os.path.exists(target_path):
            try:
                if os.path.isdir(target_path): shutil.rmtree(target_path); log.append(f"🗑️ Deleted Node: {target_path}")
                else: os.remove(target_path); log.append(f"🗑️ Deleted Model: {target_path}")
            except Exception as e: log.append(f"❌ Failed to delete {target_path}: {e}")
        else:
            log.append(f"⚠️ Already removed: {target_path}")
        hist =[h for h in hist if h['path'] != target_path]
    save_history(hist)
    return "\n".join(log), refresh_history_ui()

def load_media(file_path):
    if isinstance(file_path, list): file_path = file_path[0] if file_path else None
    if not file_path or not isinstance(file_path, str) or not os.path.isfile(file_path):
        return gr.update(value=None, visible=False), gr.update(value=None, visible=False)
    ext = os.path.splitext(file_path)[1].lower()
    if ext in['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp']:
        return gr.update(value=file_path, visible=True), gr.update(value=None, visible=False)
    elif ext in['.mp4', '.mkv', '.avi', '.webm']:
        return gr.update(value=None, visible=False), gr.update(value=file_path, visible=True)
    return gr.update(value=None, visible=False), gr.update(value=None, visible=False)

with gr.Blocks(theme=gr.themes.Soft()) as demo:
    gr.Markdown("# 🛰️ ComfyUI Universal Sidecar")
    with gr.Tabs():
        with gr.TabItem("📦 Downloader & Sync"):
            gr.Markdown("**Nodes** (Raw URLs or `.git`) & **Models** (Direct URL with tags) | Auto-injects tokens.txt")
            file_input = gr.File(label="1. Drop sync.txt or custom_nodes.txt here", file_types=[".txt"], type="filepath")
            with gr.Row():
                start_btn = gr.Button("🚀 Start Sync", variant="primary")
                cancel_btn = gr.Button("🛑 Cancel Sync", variant="stop")
            queue_out = gr.Textbox(label="2. Download Queue & File Sizes", lines=8, interactive=False)
            output_log = gr.Textbox(label="3. Live Execution Log", lines=12, interactive=False)
            sync_event = start_btn.click(fn=sync_generator, inputs=file_input, outputs=[output_log, queue_out, file_input])
            cancel_btn.click(fn=request_cancel, outputs=output_log, cancels=[sync_event])

        with gr.TabItem("🖼️ Output Browser"):
            gr.Markdown("Click on an image or video in the tree to view it. Hit 'Refresh' if new files were generated.")
            with gr.Row():
                with gr.Column(scale=1): file_exp = gr.FileExplorer(root_dir=COMFY_OUTPUT, label="Outputs", file_count="single", interactive=True)
                with gr.Column(scale=2): img_viewer = gr.Image(label="Image Viewer", visible=False, interactive=False); vid_viewer = gr.Video(label="Video Viewer", visible=False, interactive=False)
            file_exp.change(fn=load_media, inputs=file_exp, outputs=[img_viewer, vid_viewer])

        with gr.TabItem("🗑️ History & Cleanup"):
            gr.Markdown("Manage and delete downloaded files from the disk to free up cloud storage.")
            with gr.Row():
                refresh_history_btn = gr.Button("🔄 Refresh List", variant="primary")
                delete_btn = gr.Button("🧨 Delete Selected Files", variant="stop")
            history_cbg = gr.CheckboxGroup(label="Downloaded Items (Models & Nodes)", choices=[])
            delete_log = gr.Textbox(label="Cleanup Log", lines=6, interactive=False)
            refresh_history_btn.click(fn=refresh_history_ui, outputs=history_cbg)
            delete_btn.click(fn=delete_selected_files, inputs=history_cbg, outputs=[delete_log, history_cbg])
            demo.load(fn=refresh_history_ui, outputs=history_cbg)

if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=8080)