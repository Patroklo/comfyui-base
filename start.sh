#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
VENV_ARCHIVE="$COMFYUI_DIR/archive_name.tar"   # adjust if the tar lives elsewhere
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
PIP_CONSTRAINT_FILE="/opt/comfyui-runtime-constraints.txt"
R2_VENV_ARCHIVE="archive_name.tar"             # path of the tar inside the R2 bucket (relative to R2_BUCKET_PATH)



# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh
    
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."
    
    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"
    
    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true
    
    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"
    
    # Export to multiple locations for maximum compatibility
    printenv | grep -E '^RUNPOD_|^R2_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^PIP_CONSTRAINT=' | while read -r line; do
        # Get variable name and value
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        # Add to /etc/environment (system-wide)
        echo "$name=\"$value\"" >> "$ENV_FILE"
        
        # Add to PAM environment
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        
        # Add to SSH environment file
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        
        # Add to current shell
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done
    
    # Add sourcing to shell startup files
    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc
    
    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# ---------------------------------------------------------------------------- #
#  Hydrate content from Cloudflare R2.                                          #
#                                                                              #
#  The bucket is a FULL ComfyUI checkout plus extra tools, so we DON'T pull    #
#  "everything minus core" (root files like main.py would clobber the image's  #
#  ComfyUI). Instead we pull two explicit lists:                               #
#    - COMFY_DATA_DIRS  -> into the ComfyUI dir (models, custom_nodes, ...)     #
#    - SIBLING_DIRS     -> into /workspace/runpod-slim (standalone tools/LoRAs) #
#  Add new folders to SIBLING_DIRS as you create them in the bucket.           #
# ---------------------------------------------------------------------------- #
hydrate_from_r2() {
    # Accept bare or -prefixed names.
    local R2_KEY="${R2_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
    local R2_SECRET="${R2_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
    local R2_END="${R2_ENDPOINT:-${R2_ENDPOINT:-}}"
    local R2_PATH="${R2_BUCKET_PATH:-${R2_BUCKET_PATH:-pruebacomfyui/ComfyUi}}"

    if [ -z "$R2_KEY" ] || [ -z "$R2_SECRET" ] || [ -z "$R2_END" ]; then
        echo "R2 env vars not set — skipping R2 hydrate (stock behaviour)."
        return
    fi

    echo "============================================="
    echo "  Hydrating content from Cloudflare R2"
    echo "============================================="

    if ! command -v rclone >/dev/null 2>&1; then
        echo "rclone not found — installing via .deb..."
        curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.deb -o /tmp/rclone.deb
        dpkg -i /tmp/rclone.deb || (apt-get update && apt-get install -f -y /tmp/rclone.deb) || {
            echo "WARNING: rclone install failed; skipping R2 hydrate."
            return 0
        }
        rm -f /tmp/rclone.deb
    fi

    # Remote defined from env — provider MUST be "Other" for Cloudflare R2
    # (rclone's "Cloudflare" provider value is rejected by this build).
    export RCLONE_CONFIG_MANGA_R2_TYPE="s3"
    export RCLONE_CONFIG_MANGA_R2_PROVIDER="Other"
    export RCLONE_CONFIG_MANGA_R2_ACCESS_KEY_ID="$R2_KEY"
    export RCLONE_CONFIG_MANGA_R2_SECRET_ACCESS_KEY="$R2_SECRET"
    export RCLONE_CONFIG_MANGA_R2_ENDPOINT="$R2_END"
    export RCLONE_CONFIG_MANGA_R2_REGION="auto"
    export RCLONE_CONFIG_MANGA_R2_ACL="private"

    # strip any scheme from the endpoint for connection-string form
    local EP="${R2_END#https://}"; EP="${EP#http://}"
    local R2_BASE=":s3,provider=Other,access_key_id=${R2_KEY},secret_access_key=${R2_SECRET},endpoint=${EP}:${R2_PATH}"
    echo "R2 base: $R2_BASE"

    if ! rclone lsd "$R2_BASE/" >/dev/null 2>&1; then
        echo "WARNING: cannot list $R2_BASE — check keys/endpoint/path. Error:"
        rclone lsd "$R2_BASE/" || true
        return
    fi

    local RCLONE_FLAGS=(-P --transfers 16 --checkers 32 \
        --multi-thread-streams 8 --multi-thread-cutoff 50M \
        --s3-chunk-size 64M --s3-upload-concurrency 8 \
        --fast-list --size-only \
        --exclude "**/__pycache__/**" --exclude "*/.git/**")

    # --- ComfyUI data dirs -> into the ComfyUI dir ---
    local COMFY_DATA_DIRS=("models" "custom_nodes" "user" "input" "output")
    local d
    for d in "${COMFY_DATA_DIRS[@]}"; do
        echo "--> [ComfyUI] $d"
        mkdir -p "$COMFYUI_DIR/$d"
        rclone copy "$R2_BASE/$d/" "$COMFYUI_DIR/$d/" "${RCLONE_FLAGS[@]}" \
            || echo "WARNING: sync of $d failed (continuing)."
    done

    # --- Standalone tools / LoRA dirs -> siblings of ComfyUI ---
    # Add new top-level bucket folders here as you create them.
    local SIBLING_DIRS=("ai-toolkit" "musubi-tuner" "chica_prueba_2_lora" "hombre_prueba_2_lora" "sd-scripts")
    local base_dir
    base_dir="$(dirname "$COMFYUI_DIR")"   # /workspace/runpod-slim
    for d in "${SIBLING_DIRS[@]}"; do
        echo "--> [sibling] $d"
        mkdir -p "$COMFYUI_DIR/$d"
        rclone copy "$R2_BASE/$d/" "$COMFYUI_DIR/$d/" "${RCLONE_FLAGS[@]}" \
            || echo "WARNING: sync of $d failed (continuing)."
    done

    # --- Venv archive: only download if the venv is missing and the tar isn't already here ---
    if [ ! -d "$VENV_DIR" ] && [ ! -f "$VENV_ARCHIVE" ]; then
        echo "--> [venv] downloading $R2_VENV_ARCHIVE"
        rclone copyto "$R2_BASE/$R2_VENV_ARCHIVE" "$VENV_ARCHIVE" "${RCLONE_FLAGS[@]}" \
            || echo "WARNING: download of $R2_VENV_ARCHIVE failed."
    fi

    echo "R2 hydrate complete."
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

# Install and start Cloudflare Tunnels for Web services
setup_cloudflare_tunnels() {
    echo "============================================="
    echo "  Setting up Cloudflare Tunnels..."
    echo "============================================="

    # Install cloudflared if not present
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "cloudflared not found — installing..."
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb || apt-get install -f -y /tmp/cloudflared.deb || true
        rm -f /tmp/cloudflared.deb
    fi

    # Helper function to launch quick tunnel and extract URL
    launch_quick_tunnel() {
        local name="$1"
        local url="$2"
        local logfile="/tmp/cf_${name}.log"

        nohup cloudflared tunnel --url "$url" &> "$logfile" &
        
        local cf_url=""
        for i in {1..12}; do
            cf_url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | head -n 1 || true)
            if [ -n "$cf_url" ]; then
                break
            fi
            sleep 1
        done

        if [ -n "$cf_url" ]; then
            echo "$cf_url"
        else
            echo "URL pending (check $logfile)"
        fi
    }

    echo "Launching Quick Tunnels for services..."
    COMFY_CF_URL=$(launch_quick_tunnel "comfyui" "http://localhost:8188")
    FILEBROWSER_CF_URL=$(launch_quick_tunnel "filebrowser" "http://localhost:8080")
    JUPYTER_CF_URL=$(launch_quick_tunnel "console" "http://localhost:8888")

    echo "================================================================="
    echo "                  CLOUDFLARE TUNNEL URLS                         "
    echo "================================================================="
    echo "  🎨 ComfyUI:         $COMFY_CF_URL"
    echo "  📁 FileBrowser:     $FILEBROWSER_CF_URL"
    echo "  💻 Console/Jupyter: $JUPYTER_CF_URL"
    echo "================================================================="
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Setup environment
if [ -f "$PIP_CONSTRAINT_FILE" ]; then
    export PIP_CONSTRAINT="$PIP_CONSTRAINT_FILE"
    echo "Using runtime pip constraints from $PIP_CONSTRAINT_FILE"
fi

setup_ssh
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin "${FILEBROWSER_PASSWORD:-adminadmin12}" --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

# Start FileBrowser
echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."
    cp -r /opt/comfyui-baked "$COMFYUI_DIR"
    echo "ComfyUI copied to workspace"
else
    echo "Using existing ComfyUI installation"
fi

# Restore the venv from the archive (no venv creation, no pip installs)
if [ ! -d "$VENV_DIR" ]; then
    if [ ! -f "$VENV_ARCHIVE" ]; then
        echo "ERROR: venv archive not found at $VENV_ARCHIVE"
        exit 1
    fi
    echo "Restoring venv from $VENV_ARCHIVE..."
    tar -xf "$VENV_ARCHIVE" -C "$COMFYUI_DIR"
    echo "venv restored"
fi

source "$VENV_DIR/bin/activate"


# ---- R2 hydrate: pull user content, then install its custom-node deps -------
# Placed AFTER ComfyUI setup (so the dirs exist and the venv is active) and
# BEFORE the ComfyUI launch (which blocks on `wait`). The venv is active at
# this point via one of the branches above.
hydrate_from_r2
# -----------------------------------------------------------------------------

# Warm up pip so ComfyUI-Manager's 5s timeout check doesn't fail on cold start
python -m pip --version > /dev/null 2>&1

# Start ComfyUI — keep container alive if it crashes so SSH/Jupyter remain accessible
cd $COMFYUI_DIR
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
python main.py $FIXED_ARGS &
COMFY_PID=$!
trap "kill $COMFY_PID 2>/dev/null" SIGTERM SIGINT

# Setup Cloudflare Tunnels & log URLs
setup_cloudflare_tunnels

wait $COMFY_PID || true

echo "============================================="
echo "  ComfyUI crashed — check the logs above."
echo "  SSH and JupyterLab are still available."
echo "  To restart after fixing:"
echo "    cd $COMFYUI_DIR && source .venv-cu128/bin/activate"
echo "    python main.py $FIXED_ARGS"
echo "============================================="

sleep infinity
