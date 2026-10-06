#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
BAKED_COMFYUI_DIR="/opt/comfyui-baked"
BUNDLE_VERSION_FILE=".runpod-bundle-version"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
OLD_VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
PIP_CONSTRAINT_FILE="/opt/comfyui-runtime-constraints.txt"
BAKED_NODES=("ComfyUI-Manager" "ComfyUI-KJNodes" "Civicomfy" "ComfyUI-RunpodDirect")

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
#  Cloudflare R2 content sync (both directions).                               #
#                                                                              #
#  The bucket is a FULL ComfyUI checkout (core code, .venv-cu128, models,       #
#  custom_nodes, and sibling tool/LoRA dirs all under one prefix). We mirror    #
#  the whole prefix in or out as a single rclone copy — no per-folder lists.   #
# ---------------------------------------------------------------------------- #

# Shared rclone transfer flags for both hydrate (R2 -> pod) and push (pod -> R2).
R2_SYNC_FLAGS=(-P --transfers 16 --checkers 32 \
    --multi-thread-streams 8 --multi-thread-cutoff 50M \
    --s3-chunk-size 64M --s3-upload-concurrency 8 \
    --fast-list --size-only \
    --exclude "/.git/**" --exclude "/.github/**" --exclude "/.ci/**" \
    --exclude "**/__pycache__/**")

# Configure the rclone remote from R2_* env vars and set $R2_BASE / $R2_PATH.
# Returns 1 (no output of its own) when R2 isn't configured, so callers can
# decide what to log. Installs rclone on demand if it's missing.
r2_configure() {
    local R2_KEY="${R2_ACCESS_KEY_ID:-}"
    local R2_SECRET="${R2_SECRET_ACCESS_KEY:-}"
    local R2_END="${R2_ENDPOINT:-}"
    R2_PATH="${R2_BUCKET_PATH:-pruebacomfyui/ComfyUi}"

    if [ -z "$R2_KEY" ] || [ -z "$R2_SECRET" ] || [ -z "$R2_END" ]; then
        return 1
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        echo "rclone not found — installing via .deb..."
        curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.deb -o /tmp/rclone.deb
        dpkg -i /tmp/rclone.deb || (apt-get update && apt-get install -f -y /tmp/rclone.deb) || {
            echo "WARNING: rclone install failed."
            return 1
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
    R2_BASE=":s3,provider=Other,access_key_id=${R2_KEY},secret_access_key=${R2_SECRET},endpoint=${EP}:${R2_PATH}"
    return 0
}

# Pull the bucket down into $COMFYUI_DIR (R2 -> pod).
hydrate_from_r2() {
    r2_configure || { echo "R2 env vars not set — skipping R2 hydrate (stock behaviour)."; return; }

    echo "============================================="
    echo "  Hydrating content from Cloudflare R2"
    echo "============================================="
    echo "R2 target: $R2_PATH"

    if ! rclone lsd "$R2_BASE/" >/dev/null 2>&1; then
        echo "WARNING: cannot list $R2_PATH — check keys/endpoint/path. Error:"
        rclone lsd "$R2_BASE/" 2>&1 | sed -E 's#(access_key_id|secret_access_key)=[^,:]*#\1=***REDACTED***#g' || true
        return
    fi

    mkdir -p "$COMFYUI_DIR"
    echo "--> Mirroring $R2_PATH -> $COMFYUI_DIR"
    rclone copy "$R2_BASE/" "$COMFYUI_DIR/" "${R2_SYNC_FLAGS[@]}" \
        || { echo "WARNING: R2 hydrate failed (continuing)."; return; }

    echo "R2 hydrate complete."
    R2_HYDRATED=1
}

# Push local workspace changes up to the bucket (pod -> R2). Non-destructive:
# uses `rclone copy`, so files deleted locally are left alone in the bucket.
push_to_r2() {
    r2_configure || { echo "R2 env vars not set — skipping R2 push."; return 1; }

    if [ ! -d "$COMFYUI_DIR" ]; then
        echo "WARNING: $COMFYUI_DIR does not exist yet — nothing to push."
        return 1
    fi

    echo "============================================="
    echo "  Pushing local changes to Cloudflare R2"
    echo "============================================="
    echo "R2 target: $R2_PATH"

    rclone copy "$COMFYUI_DIR/" "$R2_BASE/" "${R2_SYNC_FLAGS[@]}" \
        || { echo "WARNING: R2 push failed."; return 1; }

    echo "R2 push complete."
}

# Background loop: push local changes to R2 every 30 minutes. Only started
# when R2 is configured (checked by the caller via $R2_ENABLED).
start_periodic_r2_push() {
    (
        # set -e is inherited from the parent script; without this, a single
        # failed push (non-zero return from push_to_r2) would kill this
        # subshell and silently end the periodic sync for the rest of the
        # pod's life. +e keeps the loop alive across failures.
        set +e
        while true; do
            sleep 1800
            echo "[r2-push] periodic sync starting..."
            push_to_r2 || echo "[r2-push] push failed — will retry in 30m"
        done
    ) &> /r2-push.log &
    echo "Periodic R2 push scheduled every 30 minutes (PID $!, log: /r2-push.log)"
}

# Install requirements for user custom nodes pulled from R2
run_node_requirements() {
    [ "${R2_HYDRATED:-0}" = "1" ] || return
    echo "Installing requirements for R2-provided custom nodes..."
    local req node
    for req in "$COMFYUI_DIR"/custom_nodes/*/requirements.txt; do
        [ -f "$req" ] || continue
        node=$(basename "$(dirname "$req")")
        case " ${BAKED_NODES[*]} " in
            *" $node "*) continue ;;
        esac
        echo "  - $node"
        pip install -r "$req" 2>&1 | grep -E "^(Successfully|ERROR)" || true
    done
    echo "Custom-node requirements install complete."
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

# Upgrade the image-managed ComfyUI files while leaving user data on the
# persistent workspace untouched.
upgrade_comfyui_if_needed() {
    local baked_manifest="$BAKED_COMFYUI_DIR/$BUNDLE_VERSION_FILE"
    local installed_manifest="$COMFYUI_DIR/$BUNDLE_VERSION_FILE"

    # A missing workspace is handled by the first-time setup below.
    if [ ! -d "$COMFYUI_DIR" ]; then
        return
    fi

    if [ ! -f "$baked_manifest" ]; then
        echo "WARNING: Baked ComfyUI bundle manifest is missing; skipping upgrade"
        return
    fi

    if [ -f "$installed_manifest" ] && cmp -s "$baked_manifest" "$installed_manifest"; then
        echo "Using existing ComfyUI installation (bundle is current)"
        return
    fi

    echo "============================================="
    echo "  Upgrading ComfyUI workspace from baked bundle"
    echo "  Preserving models, user data, and custom nodes"
    echo "============================================="

    # Sync ComfyUI core and remove files that no longer exist in the new
    # release. Excluded paths belong to the user or are managed separately.
    rsync -a --delete \
        --exclude="/$BUNDLE_VERSION_FILE" \
        --exclude="/.venv*" \
        --exclude="/models" \
        --exclude="/input" \
        --exclude="/output" \
        --exclude="/user" \
        --exclude="/custom_nodes" \
        --exclude="/extra_model_paths.yaml" \
        "$BAKED_COMFYUI_DIR/" "$COMFYUI_DIR/"

    mkdir -p "$COMFYUI_DIR/custom_nodes"

    # Update files located directly under custom_nodes without deleting
    # user-provided files or directories.
    rsync -a --exclude="*/" \
        "$BAKED_COMFYUI_DIR/custom_nodes/" "$COMFYUI_DIR/custom_nodes/"

    # Image-managed nodes are pinned with the image and must be upgraded.
    # Other custom-node directories are user-owned and remain untouched.
    local node
    for node in "${BAKED_NODES[@]}"; do
        if [ -d "$BAKED_COMFYUI_DIR/custom_nodes/$node" ]; then
            mkdir -p "$COMFYUI_DIR/custom_nodes/$node"
            rsync -a --delete \
                "$BAKED_COMFYUI_DIR/custom_nodes/$node/" \
                "$COMFYUI_DIR/custom_nodes/$node/"
        fi
    done

    # Write the manifest only after every sync succeeds. An interrupted
    # migration is retried on the next container start.
    cp "$baked_manifest" "${installed_manifest}.tmp"
    mv "${installed_manifest}.tmp" "$installed_manifest"
    echo "ComfyUI workspace upgraded successfully"
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

    # Mirror the same URLs to a file on the persistent workspace, overwriting
    # any URLs left over from a previous boot (tunnels are regenerated every
    # start, so stale entries would otherwise point nowhere).
    local tunnel_file="/workspace/runpod-slim/tunnel_urls.txt"
    {
        echo "================================================================="
        echo "                  CLOUDFLARE TUNNEL URLS                         "
        echo "================================================================="
        echo "  🎨 ComfyUI:         $COMFY_CF_URL"
        echo "  📁 FileBrowser:     $FILEBROWSER_CF_URL"
        echo "  💻 Console/Jupyter: $JUPYTER_CF_URL"
        echo "================================================================="
    } > "$tunnel_file"
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Manual one-off push: `start.sh --push-r2` runs just the R2 push and exits,
# without touching SSH/FileBrowser/Jupyter/ComfyUI. Useful to trigger a sync
# on demand from inside a running pod (e.g. via SSH) between the automatic
# 30-minute pushes.
if [ "${1:-}" = "--push-r2" ]; then
    push_to_r2
    exit $?
fi

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

# Detect whether R2 hydrate is configured. When it is, R2 is the source of
# truth for ComfyUI core + venv + models + custom nodes, so we skip the
# baked-image upgrade path (it would otherwise overwrite the R2-provided
# core with the stock image-baked ComfyUI on every restart).
R2_ENABLED=0
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ENDPOINT" ]; then
    R2_ENABLED=1
fi

if [ "$R2_ENABLED" = "0" ]; then
    upgrade_comfyui_if_needed
fi

# Migrate old CUDA 12.4 venv to cu128
if [ -d "$OLD_VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
    NODE_COUNT=$(find "$COMFYUI_DIR/custom_nodes" -maxdepth 2 -name "requirements.txt" 2>/dev/null | wc -l)
    echo "============================================="
    echo "  CUDA 12.4 -> 12.8 migration"
    echo "  Reinstalling deps for $NODE_COUNT custom nodes"
    echo "  This may take several minutes"
    echo "============================================="
    mv "$OLD_VENV_DIR" "${OLD_VENV_DIR}.bak"
    cd "$COMFYUI_DIR"
    python3.12 -m venv --system-site-packages "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    python -m ensurepip
    # Skip nodes baked into the image — their deps are in system site-packages
    BAKED_NODES_STR="ComfyUI-Manager ComfyUI-KJNodes Civicomfy ComfyUI-RunpodDirect"
    CURRENT=0
    INSTALLED=0
    for req in "$COMFYUI_DIR"/custom_nodes/*/requirements.txt; do
        if [ -f "$req" ]; then
            NODE_NAME=$(basename "$(dirname "$req")")
            case " $BAKED_NODES_STR " in
                *" $NODE_NAME "*) continue ;;
            esac
            CURRENT=$((CURRENT + 1))
            echo "[$CURRENT] $NODE_NAME"
            pip install -r "$req" 2>&1 | grep -E "^(Successfully|ERROR)" || true
            INSTALLED=$((INSTALLED + 1))
        fi
    done
    echo "Ensuring ComfyUI requirements are present..."
    pip install -r "$COMFYUI_DIR/requirements.txt" 2>&1 | grep -E "^(Successfully|ERROR)" || true
    echo "Migration complete — $INSTALLED user nodes processed (${NODE_COUNT} total, baked nodes skipped)"
    echo "Old venv backed up at ${OLD_VENV_DIR}.bak — delete it to free space:"
    echo "  rm -rf ${OLD_VENV_DIR}.bak"
fi

# ---- R2 hydrate: pull ComfyUI core + venv + models + custom nodes ----------
# Placed BEFORE the "Setup ComfyUI if needed" block below, so that when R2 is
# configured it populates $COMFYUI_DIR and $VENV_DIR directly from the
# bucket — the block below then finds both already present and just
# activates the venv, instead of copying the baked image and building a
# throwaway venv first.
hydrate_from_r2
# -----------------------------------------------------------------------------

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."

    # Copy baked ComfyUI from image (no git, no network)
    if [ ! -d "$COMFYUI_DIR" ]; then
        cp -r /opt/comfyui-baked "$COMFYUI_DIR"
        echo "ComfyUI copied to workspace"
    fi

    # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        # Ensure pip is available in the venv (needed for ComfyUI-Manager)
        python -m ensurepip

        echo "Base packages (torch, numpy, etc.) available from system site-packages"
        echo "ComfyUI ready — all dependencies pre-installed in image"
    fi
else
    # Just activate the existing venv
    source "$VENV_DIR/bin/activate"
    echo "Using existing ComfyUI installation"
fi

# Install requirements for any R2-provided custom node not already covered
# by the active venv. Runs after the venv is guaranteed to be activated.
run_node_requirements

# Schedule the automatic push-to-R2 loop (every 30 min). Only when R2 is
# actually configured — mirrors the hydrate-side $R2_ENABLED gate above.
if [ "$R2_ENABLED" = "1" ]; then
    start_periodic_r2_push
fi

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
