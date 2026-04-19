import gradio as gr
import os, subprocess, re, requests, shutil, json, time
from urllib.parse import urlparse

COMFY_ROOT = "/app"
COMFY_OUTPUT = os.path.join(COMFY_ROOT, "output")
HISTORY_FILE = "/app/sidecar_history.json"
TOKENS_FILE = "/app/tokens.txt"
VENV_PIP = "pip"

os.makedirs(COMFY_OUTPUT, exist_ok=True)
current_process = None
cancel_requested = False
tools_running = {}

# --- APP HUB (LAUNCHERS) ---
def launch_ollama_webui():
    if tools_running.get("ollama"): return "✅ Ollama & Open WebUI already running!"
    try:
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = os.environ.copy()
        env["PORT"] = "8081"; env["HOST"] = "0.0.0.0"
        subprocess.Popen(["/app/venv_openwebui/bin/open-webui", "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tools_running["ollama"] = True
        return "🚀 SUCCESS! Connect to Port [8081]."
    except Exception as e: return f"❌ Failed: {e}"

def launch_langflow():
    if tools_running.get("langflow"): return "✅ Langflow already running!"
    try:
        subprocess.Popen(["/app/venv_langflow/bin/python", "-m", "langflow", "run", "--host", "0.0.0.0", "--port", "7860"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tools_running["langflow"] = True
        return "🚀 SUCCESS! Connect to Port [7860]."
    except Exception as e: return f"❌ Failed: {e}"

def launch_vscode():
    if tools_running.get("vscode"): return "✅ VS Code already running!"
    try:
        subprocess.Popen(["code-server", "--auth", "none", "--bind-addr", "0.0.0.0:8082", "/app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tools_running["vscode"] = True
        return "🚀 SUCCESS! Connect to Port [8082]."
    except Exception as e: return f"❌ Failed: {e}"

def launch_kohya():
    if tools_running.get("kohya"): return "✅ Kohya_ss already running!"
    try:
        subprocess.Popen(["/app/venv_kohya/bin/python", "kohya_gui.py", "--listen", "0.0.0.0", "--server_port", "28000", "--headless"], cwd="/app/kohya_ss", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tools_running["kohya"] = True
        return "🚀 SUCCESS! Connect to Port [28000]."
    except Exception as e: return f"❌ Failed: {e}"

def launch_tensorboard():
    if tools_running.get("tensorboard"): return "✅ TensorBoard already running!"
    try:
        os.makedirs("/app/kohya_ss/logs", exist_ok=True)
        subprocess.Popen(["tensorboard", "--logdir", "/app/kohya_ss/logs", "--host", "0.0.0.0", "--port", "6006"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tools_running["tensorboard"] = True
        return "🚀 SUCCESS! Connect to Port[6006]."
    except Exception as e: return f"❌ Failed: {e}"

# --- UTILS & SYNCER ---
def get_tokens():
    tokens = {"HF": os.environ.get("HF_TOKEN"), "CIVITAI": os.environ.get("CIVITAI_TOKEN")}
    if os.path.exists(TOKENS_FILE):
        with open(TOKENS_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("HF_TOKEN=") and not tokens["HF"]: tokens["HF"] = line.split("=", 1)[1].strip()
                elif line.startswith("CIVITAI_TOKEN=") and not tokens["CIVITAI"]: tokens["CIVITAI"] = line.split("=", 1)[1].strip()
    return tokens

def format_bytes(s): return f"{s/1024:.1f} KB" if s < 1024**2 else (f"{s/(1024**2):.1f} MB" if s < 1024**3 else f"{s/(1024**3):.2f} GB")
def get_dir_size(p): return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(p) for f in fs if not os.path.islink(os.path.join(d, f)))

def load_history(): return json.load(open(HISTORY_FILE)) if os.path.exists(HISTORY_FILE) else[]
def save_history(h): json.dump(h, open(HISTORY_FILE, "w"), indent=4)
def append_history(n, p, i, s):
    h = [x for x in load_history() if x['path'] != p]
    h.append({"name": n, "path": p, "is_node": i, "size": s})
    save_history(h)

def request_cancel():
    global cancel_requested, current_process
    cancel_requested = True
    if current_process:
        try: current_process.kill()
        except: pass
    return "⚠️ Cancellation triggered!"

def sync_generator(file_path):
    global cancel_requested, current_process
    cancel_requested = False; current_process = None; auth_tokens = get_tokens()

    if not file_path:
        yield "❌ Error: No file uploaded.", "No queue", gr.update()
        return

    file_path = file_path.name if hasattr(file_path, "name") else file_path
    with open(file_path, "r") as f: lines = f.readlines()

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
            else: tasks.append({"url": url, "tag": tag, "custom_name": custom_name, "status": "pending", "size": "", "path": ""})

    def render_queue(c=-1):
        q = []
        for i, t in enumerate(tasks):
            n = t['custom_name'] if t['custom_name'] else t['url'].rstrip('/').split('/')[-1].replace('.git', '')
            icon = "✅" if t['status'] == "done" else ("❌" if t['status'] == "error" else ("🛑" if t['status'] == "cancelled" else ("▶️" if i == c else "⏳")))
            q.append(f"{icon} {i+1}. {n} {f'({t['size']})' if t['size'] else ''}")
        return "\n".join(q)

    log_history = []
    def log(m, r=False):
        if r and log_history and log_history[-1].startswith("   ->"): log_history[-1] = f"   -> {m}"
        else: log_history.append(f"   -> {m}" if r else m)
        return "\n".join(log_history[-20:])

    if not tasks: yield log("⚠️ No tasks."), "Empty", gr.update(); return
    yield log(f"🔍 Found {len(tasks)} tasks..."), render_queue(), gr.update()

    for i, task in enumerate(tasks):
        if cancel_requested: break
        url, tag, custom_name = task["url"], task["tag"], task["custom_name"]
        q_ui = render_queue(i)
        yield log(f"\n--- Task {i+1} of {len(tasks)} ---"), q_ui, gr.update()

        if "custom_nodes" in tag:
            repo_name = url.rstrip('/').split('/')[-1].replace(".git", "")
            target_dir = os.path.join(COMFY_ROOT, "custom_nodes", repo_name)
            if not os.path.exists(target_dir):
                yield log(f"📦 Cloning Node: {repo_name}..."), q_ui, gr.update()
                try:
                    current_process = subprocess.Popen(["git", "clone", "--depth", "1", url, target_dir], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    current_process.wait()
                    req_file = os.path.join(target_dir, "requirements.txt")
                    if os.path.exists(req_file):
                        yield log(f"⚙️ Installing dependencies..."), q_ui, gr.update()
                        subprocess.run(["sed", "-i", "-E", "/^(torch|torchvision|torchaudio|xformers)([^a-zA-Z0-9]|$)/d", req_file])
                        subprocess.run([VENV_PIP, "install", "-r", req_file])
                    tasks[i]["status"] = "done"
                    tasks[i]["size"] = format_bytes(get_dir_size(target_dir))
                    append_history(repo_name, target_dir, True, tasks[i]["size"])
                    yield log(f"✅ Finished Node: {repo_name}"), render_queue(i), gr.update()
                except Exception as e:
                    tasks[i]["status"] = "error"
                    yield log(f"❌ Error: {str(e)}"), render_queue(i), gr.update()
            else:
                tasks[i]["status"] = "done"; tasks[i]["size"] = format_bytes(get_dir_size(target_dir))
                yield log(f"ℹ️ Node exists."), render_queue(i), gr.update()

        else:
            dest_dir = os.path.join(COMFY_ROOT, tag)
            os.makedirs(dest_dir, exist_ok=True)
            file_name = custom_name if custom_name else os.path.basename(urlparse(url).path).split("?")[0]
            dest_file = os.path.join(dest_dir, file_name)
            yield log(f"⏳ Downloading: {file_name}..."), q_ui, gr.update()

            if "civitai.com" in url:
                try:
                    h = {"User-Agent": "Mozilla/5.0"}
                    if auth_tokens["CIVITAI"] and "token=" not in url: url += f"{'&' if '?' in url else '?'}token={auth_tokens['CIVITAI']}"
                    resp = requests.get(url, stream=True, headers=h)
                    resp.raise_for_status()
                    total, dl = int(resp.headers.get('content-length', 0)), 0
                    with open(dest_file, 'wb') as f:
                        for chunk in resp.iter_content(chunk_size=1048576):
                            if cancel_requested: break
                            if chunk:
                                f.write(chunk); dl += len(chunk)
                                if total > 0: yield log(f"[{int((dl/total)*100)}% | {format_bytes(dl)} / {format_bytes(total)}]", True), q_ui, gr.update()
                    if cancel_requested: tasks[i]["status"] = "cancelled"; continue
                    tasks[i]["status"] = "done"; tasks[i]["size"] = format_bytes(os.path.getsize(dest_file))
                    append_history(file_name, dest_file, False, tasks[i]["size"])
                    yield log(f"✅ Downloaded!"), render_queue(i), gr.update()
                except Exception as e: tasks[i]["status"] = "error"; yield log(f"❌ Error: {str(e)}"), render_queue(i), gr.update()
            else:
                cmd =["aria2c", "--allow-overwrite=true", "--auto-file-renaming=false", "-x", "16", "-s", "16", "-d", dest_dir, "-o", file_name]
                if "huggingface.co" in url and auth_tokens["HF"]: cmd.append(f"--header=Authorization: Bearer {auth_tokens['HF']}")
                cmd.append(url)
                try:
                    current_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    for out in current_process.stdout:
                        if cancel_requested: current_process.kill(); break
                        m = re.search(r"([\d\.]+[KMG]?iB)/([\d\.]+[KMG]?iB)\((\d+)%\)", out.strip())
                        if m: yield log(f"[{m.group(3)}% | {m.group(1)} / {m.group(2)}]", True), q_ui, gr.update()
                    current_process.wait()
                    if current_process.returncode == 0:
                        tasks[i]["status"] = "done"; tasks[i]["size"] = format_bytes(os.path.getsize(dest_file))
                        append_history(file_name, dest_file, False, tasks[i]["size"])
                        yield log(f"✅ Downloaded!"), render_queue(i), gr.update()
                    else: tasks[i]["status"] = "error"; yield log(f"❌ Error Code {current_process.returncode}"), render_queue(i), gr.update()
                except Exception as e: tasks[i]["status"] = "error"; yield log(f"❌ Error: {str(e)}"), render_queue(i), gr.update()

    yield log("🔄 Refreshing ComfyUI..."), render_queue(), gr.update(value=None)
    try: requests.post("http://127.0.0.1:8188/api/refresh", timeout=5)
    except: pass

def refresh_hist(): return gr.update(choices=[f"{'📦 NODE' if h['is_node'] else '🗂️ MODEL'} | {h['name']} ({h['size']}) -> {h['path']}" for h in load_history() if os.path.exists(h['path'])])
def del_files(sel):
    l, h = [], load_history()
    for s in (sel or[]):
        p = s.split(" -> ")[-1].strip()
        if os.path.exists(p): shutil.rmtree(p) if os.path.isdir(p) else os.remove(p); l.append(f"🗑️ Deleted: {p}")
        h =[x for x in h if x['path'] != p]
    save_history(h)
    return "\n".join(l) if l else "⚠️ Nothing selected.", refresh_hist()

# --- UI BUILDER ---
with gr.Blocks(theme=gr.themes.Soft()) as demo:
    gr.Markdown("# 🛰️ ComfyUI Ultimate Sidecar")
    with gr.Tabs():
        with gr.TabItem("📦 Sync & Download"):
            f_in = gr.File(label="Drop sync.txt", file_types=[".txt"], type="filepath")
            with gr.Row():
                btn_start = gr.Button("🚀 Start", variant="primary")
                btn_cancel = gr.Button("🛑 Cancel", variant="stop")
            q_out = gr.Textbox(label="Queue", lines=8); log_out = gr.Textbox(label="Log", lines=12)
            sync_ev = btn_start.click(sync_generator, f_in, [log_out, q_out, f_in])
            btn_cancel.click(request_cancel, None, log_out, cancels=[sync_ev])

        with gr.TabItem("🗑️ File Manager"):
            with gr.Row():
                btn_ref = gr.Button("🔄 Refresh"); btn_del = gr.Button("🧨 Delete", variant="stop")
            cbg = gr.CheckboxGroup(label="Downloaded Items"); del_log = gr.Textbox(label="Log")
            btn_ref.click(refresh_hist, None, cbg); btn_del.click(del_files, cbg,[del_log, cbg]); demo.load(refresh_hist, None, cbg)

        with gr.TabItem("🛠️ Application Hub"):
            gr.Markdown("Click to launch massive applications in the background. Access them instantly via the RunPod connect menu ports.")
            with gr.Row():
                with gr.Column():
                    b1 = gr.Button("🧠 Launch OpenWebUI & Ollama"); t1 = gr.Textbox(label="Status")
                    b1.click(launch_ollama_webui, None, t1); gr.Markdown("*Runs locally on Port **8081**.*")
                with gr.Column():
                    b2 = gr.Button("⛓️ Launch Langflow"); t2 = gr.Textbox(label="Status")
                    b2.click(launch_langflow, None, t2); gr.Markdown("*Runs locally on Port **7860**.*")
                with gr.Column():
                    b3 = gr.Button("💻 Launch VS Code"); t3 = gr.Textbox(label="Status")
                    b3.click(launch_vscode, None, t3); gr.Markdown("*Runs locally on Port **8082**.*")
            gr.Markdown("---")
            with gr.Row():
                with gr.Column():
                    b4 = gr.Button("🔥 Launch Kohya_ss Trainer"); t4 = gr.Textbox(label="Status")
                    b4.click(launch_kohya, None, t4); gr.Markdown("*Runs locally on Port **28000**.*")
                with gr.Column():
                    b5 = gr.Button("📊 Launch TensorBoard"); t5 = gr.Textbox(label="Status")
                    b5.click(launch_tensorboard, None, t5); gr.Markdown("*Runs locally on Port **6006**.*")
                with gr.Column():
                    gr.Markdown("### 📂 Bulk FileBrowser\nFileBrowser is already running natively!\n\n*Click Connect to **Port 8083** on RunPod to mass-upload files.*")

if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=8080)