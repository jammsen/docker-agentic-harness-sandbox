# Tool configuration — syncs Claude Code config, renders model templates,
# links opencode auth. All sources are mounted by compose.yml.

sync_claude_config() {
    # Runs on every start so config changes always take effect. Sources are
    # mounted read-only at ~/.config/claude-*; ~/.claude/ is a rw volume
    # (session state lives there alongside the synced files). ~/.claude.json is
    # in the writable container layer — written here so onboarding/trust state
    # is always correct even after a container restart or recreation.
    local src_settings="$APP_HOME/.config/claude-settings.json"
    local src_claude_md="$APP_HOME/.config/claude-CLAUDE.md"
    local src_agents="$APP_HOME/.config/claude-agents"
    local src_json="$APP_HOME/.config/claude.json"
    local claude_dir="$APP_HOME/.claude"
    local claude_json="$APP_HOME/.claude.json"

    [[ -f "$src_settings" ]] || return 0
    mkdir -p "$claude_dir/agents"
    chown "$APP_USER":"$APP_GROUP" "$claude_dir" "$claude_dir/agents"
    install -m644 -o "$APP_USER" -g "$APP_GROUP" "$src_settings" "$claude_dir/settings.json"
    install -m644 -o "$APP_USER" -g "$APP_GROUP" "$src_claude_md" "$claude_dir/CLAUDE.md"
    if [[ -d "$src_agents" ]]; then
        rm -f "$claude_dir/agents/"*.md 2>/dev/null || true
        find "$src_agents" -name '*.md' | while IFS= read -r f; do
            install -m644 -o "$APP_USER" -g "$APP_GROUP" "$f" "$claude_dir/agents/$(basename "$f")"
        done
    fi
    [[ -f "$src_json" ]] && install -m600 -o "$APP_USER" -g "$APP_GROUP" "$src_json" "$claude_json"
    e "> Claude Code config synced to $claude_dir and $claude_json"
}

# envsubst gets an explicit variable list so nothing else that looks like $VAR
# in the configs (e.g. "$schema") is touched.
_MODEL_VARS='${MODEL_URL} ${MODEL_ID} ${MODEL_NAME} ${MODEL_CONTEXT} ${MODEL_MAX_TOKENS} ${VISION_MODEL_URL} ${VISION_MODEL_ID} ${VISION_MODEL_NAME} ${VISION_MODEL_CONTEXT} ${VISION_MODEL_MAX_TOKENS}'

_render_template() { # <src> <dst>
    local src="$1" dst="$2"
    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dst")"
    envsubst "$_MODEL_VARS" < "$src" > "$dst"
    # chmod before chown: after the chown root no longer owns the file, and
    # chmod on a non-owned file needs CAP_FOWNER, which compose drops.
    chmod 644 "$dst"
    chown "$APP_USER":"$APP_GROUP" "$dst"
    e "> Rendered $(basename "$src") -> $dst"
}

render_tool_templates() {
    local template_dir="$APP_HOME/.config/templates"
    _render_template "$template_dir/opencode.json"   "$APP_HOME/.config/opencode/opencode.json"
    _render_template "$template_dir/omp-config.yml"  "$APP_HOME/.omp/agent/config.yml"
    _render_template "$template_dir/omp-models.yml"  "$APP_HOME/.omp/agent/models.yml"
    chown "$APP_USER":"$APP_GROUP" "$APP_HOME/.config/opencode" "$APP_HOME/.omp" "$APP_HOME/.omp/agent" 2>/dev/null || true
}

link_opencode_auth() {
    # Link auth.json into place instead of bind-mounting it directly at
    # .local/share/opencode/auth.json — that path is nested inside the
    # .local/share/opencode dir mount, and Docker Desktop for Mac's virtiofs
    # backend fails to create nested mountpoints ("mountpoint ... is outside of
    # rootfs"). The source stays a live bind mount at a non-nested path, so
    # host edits to config/opencode/auth.json still apply immediately.
    local auth_src="$APP_HOME/.config/opencode-auth.json"
    local data_dir="$APP_HOME/.local/share/opencode"

    [[ -f "$auth_src" ]] || return 0
    mkdir -p "$data_dir"
    chown "$APP_USER":"$APP_GROUP" "$data_dir"
    ln -sf "$auth_src" "$data_dir/auth.json"
    e "> opencode auth.json linked into $data_dir"
}
