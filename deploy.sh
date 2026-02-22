#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
#  n8n Stack – Smart Deploy Script
#  Detects GPU availability and deploys with the right profile & model
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colors ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[n8n]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠️  $*${NC}"; }
err()  { echo -e "${RED}  ❌ $*${NC}"; }
hr()   { echo -e "${CYAN}──────────────────────────────────────────────${NC}"; }

# ── Detect container runtime ──────────────────────────────────────────
if command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
    RUNTIME="podman"
elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
    COMPOSE="docker compose"
    RUNTIME="docker"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
    RUNTIME="docker"
else
    err "No container runtime found. Install podman-compose or docker compose."
    exit 1
fi

log "Using ${BOLD}${COMPOSE}${NC} (runtime: ${RUNTIME})"

# ── Detect NVIDIA GPU ─────────────────────────────────────────────────
detect_gpu() {
    if [[ "${FORCE_CPU:-false}" == "true" ]]; then
        return 1
    fi

    # Method 1: nvidia-smi (driver installed)
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
        return 0
    fi

    # Method 2: lspci (hardware detection without driver)
    if command -v lspci &>/dev/null; then
        GPU_NAME=$(lspci | grep -i 'nvidia.*\(VGA\|3D\|Display\)' | sed 's/.*: //' | head -1)
        if [[ -n "$GPU_NAME" ]]; then
            # Hardware detected but driver may not be working
            if ! command -v nvidia-smi &>/dev/null; then
                warn "NVIDIA GPU detected (${GPU_NAME}) but nvidia-smi not found."
                warn "Install NVIDIA Container Toolkit for GPU acceleration."
                warn "Falling back to CPU mode."
                GPU_NAME=""
                return 1
            fi
        fi
    fi

    GPU_NAME=""
    return 1
}

hr
log "${BOLD}GPU Detection${NC}"
hr

if detect_gpu; then
    PROFILE="gpu"
    MODEL_VAR="OLLAMA_MODEL_GPU"
    ok "NVIDIA GPU found: ${BOLD}${GPU_NAME}${NC}"
    log "Profile: ${BOLD}gpu${NC}"

    # ── Ensure CDI is configured for podman GPU passthrough ────────
    if [[ "$RUNTIME" == "podman" ]]; then
        CDI_OK=false
        if [[ -f /etc/cdi/nvidia.yaml ]] || [[ -f /var/run/cdi/nvidia.yaml ]]; then
            CDI_OK=true
        fi

        if ! $CDI_OK; then
            warn "CDI spec not found — generating for GPU passthrough"
            if command -v nvidia-ctk &>/dev/null; then
                sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
                ok "CDI spec generated at /etc/cdi/nvidia.yaml"
            else
                warn "nvidia-ctk not found. Installing NVIDIA Container Toolkit..."
                # Try to install via package manager
                if command -v dnf &>/dev/null; then
                    sudo dnf install -y nvidia-container-toolkit &>/dev/null
                elif command -v apt-get &>/dev/null; then
                    # Add NVIDIA repo if not present
                    if ! apt-cache show nvidia-container-toolkit &>/dev/null 2>&1; then
                        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                            | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
                        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
                        sudo apt-get update &>/dev/null
                    fi
                    sudo apt-get install -y nvidia-container-toolkit &>/dev/null
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --noconfirm nvidia-container-toolkit &>/dev/null
                else
                    err "Cannot auto-install nvidia-container-toolkit."
                    err "Install it manually: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
                    err "Then run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
                    exit 1
                fi

                # Generate CDI spec after install
                if command -v nvidia-ctk &>/dev/null; then
                    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
                    ok "nvidia-container-toolkit installed + CDI spec generated"
                else
                    err "nvidia-ctk still not found after install. Check your PATH."
                    exit 1
                fi
            fi
        else
            ok "CDI spec found"
        fi
    fi
else
    PROFILE="cpu"
    MODEL_VAR="OLLAMA_MODEL_CPU"
    warn "No NVIDIA GPU detected — using CPU mode"
    log "Profile: ${BOLD}cpu${NC}"
fi

# ── Load .env to get the model name ──────────────────────────────────
if [[ -f .env ]]; then
    # Source .env safely (only export known vars)
    MODEL_NAME=$(grep "^${MODEL_VAR}=" .env 2>/dev/null | cut -d'=' -f2- || true)
fi

# Defaults if not set in .env
if [[ "$PROFILE" == "gpu" ]]; then
    MODEL_NAME="${MODEL_NAME:-mistral}"
else
    MODEL_NAME="${MODEL_NAME:-hf.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF:Q4_K_M}"
fi

log "Ollama model: ${BOLD}${MODEL_NAME}${NC}"

# ── Validate .env secrets ─────────────────────────────────────────────
hr
log "${BOLD}Checking .env${NC}"
hr

if [[ ! -f .env ]]; then
    err ".env file not found. Copy from template and fill in secrets."
    exit 1
fi

# Core secrets that MUST be set (blocks deploy)
CORE_VARS=("POSTGRES_PASSWORD" "N8N_ENCRYPTION_KEY")
# Optional vars that can be configured later in n8n UI (warns only)
OPTIONAL_VARS=("MIST_API_TOKEN" "MIST_API_BASE_URL")

HAS_ERRORS=false
while IFS='=' read -r key value; do
    if [[ "$value" == CHANGE_ME* ]]; then
        # Check if it's an optional var
        IS_OPTIONAL=false
        for opt in "${OPTIONAL_VARS[@]}"; do
            [[ "$key" == "$opt" ]] && IS_OPTIONAL=true && break
        done

        if $IS_OPTIONAL; then
            warn "${key} not configured yet (configure later in n8n UI)"
        else
            err "${key} is not configured (still has placeholder)"
            HAS_ERRORS=true
        fi
    fi
done < <(grep -v '^\s*#' .env | grep -v '^\s*$' | grep '=')

if $HAS_ERRORS; then
    err "Fix the above .env values before deploying."
    exit 1
fi
ok ".env validated"

# ── Stop existing stack ───────────────────────────────────────────────
hr
log "${BOLD}Stopping existing containers${NC}"
hr

$COMPOSE --profile cpu  down 2>/dev/null || true
$COMPOSE --profile gpu  down 2>/dev/null || true
ok "Old containers removed"

# ── Pull images in parallel ───────────────────────────────────────────
hr
log "${BOLD}Pulling images (parallel)${NC}"
hr

log "  Pulling images for profile: ${PROFILE}..."
if ! $COMPOSE --profile "$PROFILE" pull -q; then
    warn "Some image pulls had issues (may already be cached)"
fi
ok "All images ready"

# ── Start core services first (fast) ─────────────────────────────────
hr
log "${BOLD}Starting core services${NC}"
hr

$COMPOSE up -d postgres redis qdrant n8n
ok "n8n + PostgreSQL + Redis + Qdrant started"

# ── Start Ollama with the right profile ───────────────────────────────
hr
log "${BOLD}Starting Ollama (${PROFILE} mode)${NC}"
hr

OLLAMA_SERVICE="ollama-${PROFILE}"
$COMPOSE --profile "$PROFILE" up -d "$OLLAMA_SERVICE"
ok "Ollama container started"

# ── Wait for Ollama to be ready ───────────────────────────────────────
log "Waiting for Ollama API..."
RETRIES=0
MAX_RETRIES=30
until curl -sf http://localhost:11434/ &>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge $MAX_RETRIES ]]; then
        err "Ollama failed to start after ${MAX_RETRIES} attempts"
        exit 1
    fi
    sleep 2
done
ok "Ollama API ready"

# ── Wait for Qdrant to be ready ───────────────────────────────────────
log "Waiting for Qdrant API..."
Q_RETRIES=0
until curl -sf http://localhost:6333/ &>/dev/null; do
    Q_RETRIES=$((Q_RETRIES + 1))
    if [[ $Q_RETRIES -ge $MAX_RETRIES ]]; then
        err "Qdrant failed to start after ${MAX_RETRIES} attempts"
        exit 1
    fi
    sleep 2
done
ok "Qdrant API ready"

# ── Pull the AI model ────────────────────────────────────────────────
hr
log "${BOLD}Pulling model: ${MODEL_NAME}${NC}"
hr

# Check if model already exists
if $RUNTIME exec n8n-ollama ollama list | grep -q "^${MODEL_NAME%:*}\b"; then
    EXISTING="yes"
else
    EXISTING="no"
fi

if [[ "$EXISTING" == "yes" ]]; then
    ok "Model ${MODEL_NAME} already available — skipping pull"
else
    log "Downloading ${MODEL_NAME} (this may take a few minutes)..."
    # Use ollama CLI inside the container to show progress
    $RUNTIME exec n8n-ollama ollama pull "$MODEL_NAME"
    ok "Model ${MODEL_NAME} pulled successfully"
fi

# ── Setup RAG (Ingest PDFs) ──────────────────────────────────────────
hr
log "${BOLD}Setting up Knowledge Base (RAG)${NC}"
hr

log "Pulling embedding model: nomic-embed-text..."
$RUNTIME exec n8n-ollama ollama pull nomic-embed-text

log "Ingesting PDFs into Qdrant..."
# Find the network name used by compose (usually <folder>_n8n-network)
NET_NAME=$($RUNTIME network ls --format "{{.Name}}" | grep n8n-network | head -n 1)
if [ -z "$NET_NAME" ]; then
    NET_NAME="n8n-docker_n8n-network"
fi

PROJECT=$(basename "$PWD")

$RUNTIME run --rm \
    --network "$NET_NAME" \
    -v "$(pwd)/ingest_pdf.py:/app/ingest_pdf.py:ro" \
    -v "${PROJECT}_n8n_files:/files:ro" \
    python:3.11-slim \
    bash -c "pip install -q pymupdf ollama qdrant-client && python /app/ingest_pdf.py"
ok "PDF ingestion complete"

# ── Final health check ────────────────────────────────────────────────
hr
log "${BOLD}Final Health Check${NC}"
hr

ALL_OK=true

# n8n
N8N_RETRIES=0
N8N_MAX_RETRIES=30
until curl -sf -o /dev/null http://localhost:5678/; do
    N8N_RETRIES=$((N8N_RETRIES + 1))
    if [[ $N8N_RETRIES -ge $N8N_MAX_RETRIES ]]; then
        break
    fi
    sleep 2
done

if curl -sf -o /dev/null http://localhost:5678/; then
    ok "n8n .............. http://localhost:5678"
else
    err "n8n is not responding after ${N8N_MAX_RETRIES} attempts"
    ALL_OK=false
fi

# PostgreSQL
if $RUNTIME exec n8n-postgres pg_isready -U n8n &>/dev/null; then
    ok "PostgreSQL ....... healthy"
else
    err "PostgreSQL is not healthy"
    ALL_OK=false
fi

# Redis
if $RUNTIME exec n8n-redis redis-cli ping &>/dev/null; then
    ok "Redis ............ PONG"
else
    err "Redis is not responding"
    ALL_OK=false
fi

# Qdrant
if curl -sf http://localhost:6333/ &>/dev/null; then
    ok "Qdrant ........... healthy"
else
    err "Qdrant is not responding"
    ALL_OK=false
fi

# Ollama
MODELS=$(curl -sf http://localhost:11434/api/tags 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('models', []):
    d = m.get('details', {})
    print(f\"  {m['name']} ({d.get('parameter_size','?')})\")" 2>/dev/null || echo "  (unavailable)")

if [[ "$MODELS" != "  (unavailable)" ]]; then
    ok "Ollama ........... running"
    echo -e "${GREEN}${MODELS}${NC}"
else
    err "Ollama is not responding"
    ALL_OK=false
fi

hr
if $ALL_OK; then
    echo ""
    echo -e "${GREEN}${BOLD}  🚀 Stack deployed successfully!${NC}"
    echo ""
    echo -e "  ${BOLD}Profile:${NC}  ${PROFILE}"
    echo -e "  ${BOLD}Model:${NC}    ${MODEL_NAME}"
    if [[ -n "${GPU_NAME:-}" ]]; then
        echo -e "  ${BOLD}GPU:${NC}      ${GPU_NAME}"
    fi
    echo -e "  ${BOLD}n8n UI:${NC}   http://localhost:5678"
    echo ""
else
    echo ""
    err "Some services failed. Check logs with: $COMPOSE logs"
    exit 1
fi
