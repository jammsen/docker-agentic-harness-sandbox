#!/usr/bin/env bash
# https://stackoverflow.com/questions/27669950/difference-between-euid-and-uid
set -euo pipefail
umask 0027

APP_USER=agent
APP_GROUP=agent
APP_HOME=/home/$APP_USER
readonly APP_USER APP_GROUP APP_HOME

CURRENT_GID=$(getent group "$APP_GROUP" 2>/dev/null | cut -d: -f3)
CURRENT_UID=$(id -u "$APP_USER" 2>/dev/null || echo "")

if [[ "${EUID}" -ne 0 ]]; then
    echo ">>> [Entrypoint] Requires root to run setup (creating users, fixing file ownership)."
    echo "    The container process is currently running as EUID=${EUID}. Please start the container without a --user override."
    exit 1
fi

# Validate PUID/PGID for positive integer values
if ! [[ "${PUID:-}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${PGID:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo ">>> [Config] PUID=${PUID:-<unset>} PGID=${PGID:-<unset>} — Must be positive integers"
    echo "    Also running the application user as root is not supported."
    echo "    This container is designed to drop privileges after setup. Please set positive integer values for PUID and PGID."
    exit 1
fi

NEEDS_CHOWN=false

if [[ -z "$CURRENT_GID" ]]; then
    echo "> Group '$APP_GROUP' not found — creating with GID=${PGID}"
    groupadd "$APP_GROUP" --gid "${PGID}"
    NEEDS_CHOWN=true
elif [[ "$CURRENT_GID" -ne "${PGID}" ]]; then
    echo "> Group '$APP_GROUP' found with GID=${CURRENT_GID} — updating to GID=${PGID}"
    groupmod -g "${PGID}" "$APP_GROUP" > /dev/null
    NEEDS_CHOWN=true
else
    echo "> Group '$APP_GROUP' found with correct GID=${PGID} — skipping"
fi

if [[ -z "$CURRENT_UID" ]]; then
    echo "> User '$APP_USER' not found — creating with UID=${PUID}"
    useradd -g "$APP_GROUP" -m -d "$APP_HOME" -s /bin/bash "$APP_USER" --uid "${PUID}"
    NEEDS_CHOWN=true
elif [[ "$CURRENT_UID" -ne "${PUID}" ]]; then
    echo "> User '$APP_USER' found with UID=${CURRENT_UID} — updating to UID=${PUID}"
    usermod -u "${PUID}" -g "${PGID}" "$APP_USER" > /dev/null
    NEEDS_CHOWN=true
else
    echo "> User '$APP_USER' found with correct UID=${PUID} — skipping"
fi

if [[ "$NEEDS_CHOWN" = "true" ]]; then
    # -xdev: stay on the same filesystem, skip bind mounts (avoids EPERM on :ro mounts)
    find "$APP_HOME" -xdev -exec chown "$APP_USER":"$APP_GROUP" {} +
fi

OPENCODE_WORKSPACE="/home/agent/workspace"
readonly OPENCODE_WORKSPACE
export OPENCODE_WORKSPACE

if [[ ! -d "$OPENCODE_WORKSPACE" ]]; then
    echo ">>> [Entrypoint] Workspace directory '$OPENCODE_WORKSPACE' not found — is the volume mounted?"
    exit 1
fi

# Build the ordered list of available tools from TOOLS (defined in Dockerfile, overridable in compose.yml).
# First entry is the default. Each name is validated and checked against installed binaries.
AVAILABLE_TOOLS=()
IFS=',' read -ra _TOOLS_LIST <<< "$TOOLS"
for _t in "${_TOOLS_LIST[@]}"; do
    _t="${_t// /}"  # trim whitespace
    # Validate tool name is safe (alphanumeric, hyphens, underscores only)
    if ! [[ "$_t" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "> [Warning] Skipping invalid tool name '$_t' in TOOLS"
        continue
    fi
    if gosu "$APP_USER":"$APP_GROUP" bash -c "command -v '$_t'" &>/dev/null; then
        AVAILABLE_TOOLS+=("$_t")
    else
        echo "> [Warning] Tool '$_t' listed in TOOLS but not found — skipping"
    fi
done

if [[ ${#AVAILABLE_TOOLS[@]} -eq 0 ]]; then
    echo ">>> [Entrypoint] No tools available. Ensure at least one tool binary is installed in the image."
    exit 1
fi

# If DEFAULT_TOOL is set (e.g. via --tool in start.sh), skip the interactive menu.
TOOL=""
if [[ -n "${DEFAULT_TOOL:-}" ]]; then
    for _t in "${AVAILABLE_TOOLS[@]}"; do
        if [[ "$_t" = "$DEFAULT_TOOL" ]]; then
            TOOL="$_t"
            break
        fi
    done
    if [[ -z "$TOOL" ]]; then
        echo ">>> [Entrypoint] DEFAULT_TOOL='$DEFAULT_TOOL' not available. Available: ${AVAILABLE_TOOLS[*]}"
        exit 1
    fi
    echo "> Using tool '$TOOL' (from DEFAULT_TOOL)"
elif [[ ${#AVAILABLE_TOOLS[@]} -eq 1 ]]; then
    TOOL="${AVAILABLE_TOOLS[0]}"
else
    echo ""
    echo "Select which tool to start:"
    for i in "${!AVAILABLE_TOOLS[@]}"; do
        if [[ $i -eq 0 ]]; then
            echo "  $((i+1)). ${AVAILABLE_TOOLS[$i]}  (default)"
        else
            echo "  $((i+1)). ${AVAILABLE_TOOLS[$i]}"
        fi
    done
    echo ""
    read -r -p "Enter selection [1]: " SELECTION
    case "$SELECTION" in
        ""|1) TOOL="${AVAILABLE_TOOLS[0]}" ;;
        *)
            if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [[ "$SELECTION" -ge 2 ]] && [[ "$((SELECTION-1))" -lt "${#AVAILABLE_TOOLS[@]}" ]]; then
                TOOL="${AVAILABLE_TOOLS[$((SELECTION-1))]}"
            else
                echo ">>> Invalid selection '$SELECTION' — defaulting to ${AVAILABLE_TOOLS[0]}"
                TOOL="${AVAILABLE_TOOLS[0]}"
            fi
            ;;
    esac
    echo ""
fi

# HOME → workspace so opencode session state lands on the mounted volume.
# omp keeps the real HOME (/home/agent) so it finds its config/logs there.
if [[ "$TOOL" = "opencode" ]]; then
    echo "> Set HOME to $OPENCODE_WORKSPACE (mounted workspace volume)"
    export HOME="$OPENCODE_WORKSPACE"
fi

exec /usr/sbin/gosu "$APP_USER":"$APP_GROUP" "$TOOL"
