#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MODEL="hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
MODEL_NAME="${MODEL_NAME:-$DEFAULT_MODEL}"

APP_HOME="${HOME}/.agent-harness"
LOG_DIR="${APP_HOME}/logs"
INSTALL_LOG="${LOG_DIR}/install.log"

mkdir -p "$LOG_DIR"
touch "$INSTALL_LOG"

log() {
  echo "$@" | tee -a "$INSTALL_LOG"
}

ask_yes_no() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

log "agent-harness installer"
log "Model: $MODEL_NAME"
log "Install log: $INSTALL_LOG"
log ""

if [[ "$(uname -s)" != "Linux" ]]; then
  log "ERROR: This installer targets Linux."
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  log "Detected OS: ${PRETTY_NAME:-Linux}"
else
  log "Detected OS: Linux"
fi

log ""
log "Checking RAM and swap..."
awk '
/MemTotal/ { printf "Total RAM: %.2f GB\n", $2/1024/1024 }
/MemAvailable/ { printf "Available RAM: %.2f GB\n", $2/1024/1024 }
/SwapTotal/ { printf "Total swap: %.2f GB\n", $2/1024/1024 }
/SwapFree/ { printf "Free swap: %.2f GB\n", $2/1024/1024 }
' /proc/meminfo | tee -a "$INSTALL_LOG"

log ""
log "Checking Python..."
if ! have_cmd python3; then
  log "Python3 is missing."
  if ask_yes_no "Install Python3, venv, and pip using apt?"; then
    sudo apt-get update
    sudo apt-get install -y python3 python3-venv python3-pip
  else
    log "Install Python3 manually, then rerun."
    exit 1
  fi
fi

python3 - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10+ required")
print(f"Python OK: {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
PY

log ""
log "Checking basic tools..."
MISSING_APT=()

for cmd in git curl; do
  if ! have_cmd "$cmd"; then
    MISSING_APT+=("$cmd")
  fi
done

if (( ${#MISSING_APT[@]} > 0 )); then
  log "Missing basic tools: ${MISSING_APT[*]}"
  if ask_yes_no "Install missing tools using apt?"; then
    sudo apt-get update
    sudo apt-get install -y "${MISSING_APT[@]}"
  else
    log "Install missing tools manually, then rerun."
    exit 1
  fi
else
  log "Basic tools OK."
fi

log ""
log "Checking Docker..."
if ! have_cmd docker; then
  log "Docker is missing."
  if ask_yes_no "Install Docker using apt package docker.io?"; then
    sudo apt-get update
    sudo apt-get install -y docker.io
    if ask_yes_no "Start Docker service now?"; then
      sudo systemctl enable --now docker || true
    fi
  else
    log "Docker skipped. agentctl doctor will report this."
  fi
else
  log "Docker found: $(docker --version || true)"
fi

log ""
log "Checking Node/npm..."
if ! have_cmd node || ! have_cmd npm; then
  log "Node or npm is missing."
  if ask_yes_no "Install nodejs and npm using apt?"; then
    sudo apt-get update
    sudo apt-get install -y nodejs npm
  else
    log "Node/npm skipped. Later UI inspection features will need them."
  fi
else
  log "Node found: $(node --version || true)"
  log "npm found: $(npm --version || true)"
fi

log ""
log "Checking Ollama..."
if ! have_cmd ollama; then
  log "Ollama is missing."
  if ask_yes_no "Install Ollama using official install script? It runs: curl -fsSL https://ollama.com/install.sh | sh"; then
    curl -fsSL https://ollama.com/install.sh | sh
  else
    log "Ollama skipped. Install it manually, then rerun agentctl doctor."
  fi
else
  log "Ollama found."
fi

if have_cmd ollama; then
  log ""
  log "Checking Ollama API..."
  if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama API is not responding. Trying to start ollama serve in background."
    nohup ollama serve >/tmp/agent-harness-ollama.log 2>&1 &
    sleep 3
  fi

  if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama API OK."
  else
    log "WARNING: Ollama API still not responding."
    log "Try running this in another terminal:"
    log "  ollama serve"
  fi

  log ""
  if ask_yes_no "Pull target model now: $MODEL_NAME ?"; then
    log "Pulling model. This may take time."
    set +e
    ollama pull "$MODEL_NAME" | tee -a "$INSTALL_LOG"
    MODEL_STATUS=${PIPESTATUS[0]}
    set -e

    if [[ "$MODEL_STATUS" -ne 0 ]]; then
      log "WARNING: Model pull failed. agentctl model-test will show details later."
    else
      log "Model pull completed."
    fi
  else
    log "Model pull skipped."
  fi
fi

log ""
log "Creating Python virtual environment..."
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install -e .

mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/agentctl" <<EOF2
#!/usr/bin/env bash
source "${PWD}/.venv/bin/activate"
exec python -m agent_harness.cli "\$@"
EOF2

chmod +x "$HOME/.local/bin/agentctl"

log ""
log "Installed agentctl wrapper at: $HOME/.local/bin/agentctl"

mkdir -p "$APP_HOME"

cat > "$APP_HOME/config.json" <<EOF2
{
  "model": "$MODEL_NAME",
  "default_context": 8192,
  "stress_contexts": [4096, 8192, 16384, 32768],
  "temperature": 0.2,
  "ram_limit_gb": 10,
  "approval_mode": "prompt"
}
EOF2

log ""
log "Global config written to: $APP_HOME/config.json"

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  log ""
  log "NOTE: ~/.local/bin is not in PATH for this shell."
  log "Run this after install:"
  log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

log ""
log "Running agentctl doctor..."
"$HOME/.local/bin/agentctl" doctor || true

log ""
log "Installer complete."
log ""
log "Next commands:"
log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
log "  agentctl doctor"
log "  agentctl model-test"
log "  agentctl init test-project"
log "  agentctl run test-project"
