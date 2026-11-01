#!/usr/bin/env bash
# Sourced by setup.sh. OpenCode owns package installation; this helper owns the pin and migration.
OC_TPS_PACKAGE="github:jammsen/docker-agentic-harness-sandbox#1e216859caeb6927187b888ad1f6b4502b447ba0::path:sandbox-client/config/opencode/plugin/toks"

opencode_version() {
    local version
    version="$(opencode --version 2>/dev/null)" || return 0
    [[ "$version" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] && echo "${BASH_REMATCH[0]}"
}
opencode_at_pinned_version() { [[ "$(opencode_version)" == "$OPENCODE_VERSION" ]]; }

# Keep package matching in one place for status, migration detection, and cleanup.
opencode_tps_config() {
    jq -e --arg operation "$1" --arg pkg "$OC_TPS_PACKAGE" '
      def package_name:
        if type == "array" then .[0] elif type == "object" then .package else . end;
      def legacy_tps:
        package_name | if type == "string" then
          . == "@mesaleh/opencode-tps" or startswith("@mesaleh/opencode-tps@")
        else false end;
      if $operation == "installed" then any(.plugins[]?; package_name == $pkg)
      elif $operation == "legacy" then any(.plugin[]?, .plugins[]?; legacy_tps)
      else reduce ["plugin", "plugins"][] as $key (. ;
        if .[$key] | type == "array" then .[$key] |= map(select(legacy_tps | not)) else . end)
      end
    ' "$2"
}
opencode_tps_installed() {
    [[ -f "$OC_CONFIG" ]] && opencode_tps_config installed "$OC_CONFIG" >/dev/null 2>&1
}
opencode_legacy_tps_configured() {
    local file
    for file in "$OC_CONFIG" "$OC_TUI_CONFIG" "$OC_CLI_CONFIG"; do
        [[ -f "$file" ]] && opencode_tps_config legacy "$file" >/dev/null 2>&1 && return 0
    done
    return 1
}

install_opencode() {
    local ans file
    # The CLI prefers an existing JSONC file. This setup edits JSON through jq, so fail before
    # installing anything rather than modifying a different, unbacked configuration file.
    if [[ -f "${OC_CONFIG}c" ]]; then
        ew "Native setup manages JSON; convert ${OC_CONFIG}c to opencode.json before retrying."
        return 1
    fi
    if ! opencode_at_pinned_version; then
        echo "OpenCode: ${OPENCODE_VERSION} required by the shared version pin (installed: $(opencode_version))."
        read -r -p "Install OpenCode $OPENCODE_VERSION now? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || return 1
        for file in "$OC_CONFIG" "$OC_TUI_CONFIG" "$OC_CLI_CONFIG"; do backup "$file" || return 1; done
        curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "$OPENCODE_VERSION" || return 1
        PATH="$HOME/.opencode/bin:$PATH"; export PATH
        hash -r
        opencode_at_pinned_version || { ew "OpenCode $OPENCODE_VERSION wasn't found after installation"; return 1; }
        ensure_path_in_bashrc "$HOME/.opencode/bin"
        es "OpenCode $OPENCODE_VERSION installed — restart your terminal before running it"
    fi
    # Binary version and plugin compatibility are independent checks, including on repeat runs.
    if [[ "${1:-}" == "tps" ]] || opencode_legacy_tps_configured; then
        install_opencode_tps || return 1
    fi
}

install_opencode_tps() {
    local ans file tmp
    echo "opencode-toks — V2 tok/s meter, replacing the incompatible V1 TPS plugin."
    read -r -p "Install/repair the V2 meter and replace legacy TPS registrations? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || return 1
    command -v git >/dev/null || { ew "Git is required to install the plugin from its pinned source"; return 1; }
    for file in "$OC_CONFIG" "$OC_TUI_CONFIG" "$OC_CLI_CONFIG"; do
        [[ ! -f "$file" ]] || jq -e 'type == "object"' "$file" >/dev/null || {
            ew "$file must contain a JSON object; no plugin settings were changed"; return 1;
        }
        backup "$file" || return 1
    done
    opencode plugin add "$OC_TPS_PACKAGE" || return 1
    opencode_tps_installed || { ew "$OC_CONFIG doesn't list the V2 meter — check the command output"; return 1; }
    # Remove legacy entries only after a successful replacement; preserve unrelated settings.
    for file in "$OC_CONFIG" "$OC_TUI_CONFIG" "$OC_CLI_CONFIG"; do
        [[ -f "$file" ]] || continue
        tmp="$(mktemp)" || return 1
        if opencode_tps_config clean "$file" > "$tmp"; then
            mv "$tmp" "$file" || return 1
        else
            rm -f "$tmp"
            return 1
        fi
    done
    es "opencode-toks V2 installed — restart OpenCode to load it"
}
