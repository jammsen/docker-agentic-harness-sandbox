#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Exercise the actual installer helpers with mocked binaries and temporary config files.
# Requires Bash >=4 and jq. No network access or real OpenCode installation is used.
set -euo pipefail
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "Bash >=4 required" >&2; exit 1; }
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Load the real setup without opening its menu.
# shellcheck source=../setup.sh
source "$TEST_DIR/../setup.sh"
OC_CONFIG="$TMP/opencode.json"
OC_TUI_CONFIG="$TMP/tui.json"
OC_CLI_CONFIG="$TMP/cli.json"
MOCK_VERSION_FILE="$TMP/version"
MOCK_FAIL_INSTALL=false
MOCK_FAIL_PLUGIN=false
MOCK_NO_REGISTRATION=false
MOCK_FAIL_BACKUP=false
OPENCODE_VERSION_EXPECTED="$OPENCODE_VERSION"

opencode() {
    if [[ "$1" == "--version" ]]; then
        [[ -s "$MOCK_VERSION_FILE" ]] || return 127
        cat "$MOCK_VERSION_FILE"
    elif [[ "$1 $2" == "plugin add" ]]; then
        printf '%s\n' "$3" >> "$TMP/plugin-calls"
        $MOCK_FAIL_PLUGIN && return 1
        $MOCK_NO_REGISTRATION && return 0
        [[ -f "$OC_CONFIG" ]] || echo '{}' > "$OC_CONFIG"
        jq --arg pkg "$3" '.plugins = (((.plugins // []) + [$pkg]) | unique)' \
            "$OC_CONFIG" > "$TMP/added.json"
        mv "$TMP/added.json" "$OC_CONFIG"
    else
        echo "Unexpected OpenCode invocation: $*" >&2; return 1
    fi
}
installed() {
    if [[ "$1" == "opencode" ]]; then [[ -s "$MOCK_VERSION_FILE" ]]; else command -v "$1" >/dev/null; fi
}
curl() { printf '%s\n' "$*" > "$TMP/curl-args"; echo '# mocked installer'; }
# shellcheck disable=SC2120 # Called with arguments by install_opencode in the sourced helper.
bash() {
    printf '%s\n' "$*" > "$TMP/bash-args"
    cat >/dev/null
    $MOCK_FAIL_INSTALL && return 1
    echo "$OPENCODE_VERSION_EXPECTED" > "$MOCK_VERSION_FILE"
}
ensure_path_in_bashrc() { printf '%s\n' "$1" > "$TMP/path-added"; }
cp() { if $MOCK_FAIL_BACKUP; then return 1; else command cp "$@"; fi; }
check() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
reject() { if "$@"; then echo "FAIL: expected failure: $*" >&2; exit 1; fi; }

# Recognize both release output forms; any different release must offer the shared pin.
echo "opencode v$OPENCODE_VERSION" > "$MOCK_VERSION_FILE"
check opencode_at_pinned_version
check install_opencode
check test ! -e "$TMP/curl-args"
echo "$OPENCODE_VERSION" > "$MOCK_VERSION_FILE"
check opencode_at_pinned_version
echo '2.0.29' > "$MOCK_VERSION_FILE"
reject opencode_at_pinned_version
check install_opencode <<< y
check opencode_at_pinned_version
rm -f "$TMP/curl-args"
echo '1.19.0' > "$MOCK_VERSION_FILE"
reject opencode_at_pinned_version
reject install_opencode <<< n
check test ! -e "$TMP/curl-args"

# Fresh install, V1 upgrade, and installer failure use the V2 URL and pinned release.
: > "$MOCK_VERSION_FILE"
check install_opencode <<< y
check grep -qF 'https://opencode.ai/v2/install' "$TMP/curl-args"
check grep -qF -- "--version $OPENCODE_VERSION" "$TMP/bash-args"
check opencode_at_pinned_version
echo '1.19.0' > "$MOCK_VERSION_FILE"
check install_opencode <<< y
check opencode_at_pinned_version
echo '1.19.0' > "$MOCK_VERSION_FILE"
MOCK_FAIL_INSTALL=true
reject install_opencode <<< y
reject opencode_at_pinned_version
MOCK_FAIL_INSTALL=false
echo "opencode v$OPENCODE_VERSION" > "$MOCK_VERSION_FILE"

# A V2 binary plus V1 TPS registrations still needs migration. Cover strings, version pins,
# option tuples, and V2 object entries, while preserving unrelated settings in all files.
cat > "$OC_CONFIG" <<'JSON'
{"model":"local/model","provider":{"local":{"options":{"baseURL":"http://local/v1"}}},
 "plugin":["other-server",["@mesaleh/opencode-tps",{"enabled":true}]],
 "plugins":["other-v2",{"package":"@mesaleh/opencode-tps@0.3.0"}]}
JSON
echo '{"theme":"custom","plugin":["other-tui","@mesaleh/opencode-tps@0.3.0"]}' > "$OC_TUI_CONFIG"
echo '{"keybinds":{"leader":"ctrl+x"},"plugins":["other-cli","@mesaleh/opencode-tps"]}' > "$OC_CLI_CONFIG"
check opencode_legacy_tps_configured
reject opencode_tps_installed
reject install_opencode <<< n
check opencode_legacy_tps_configured
check test ! -e "$TMP/plugin-calls"
check install_opencode <<< y
check opencode_tps_installed
reject opencode_legacy_tps_configured
check jq -e '.model == "local/model" and .provider.local.options.baseURL == "http://local/v1"
  and .plugin == ["other-server"] and (.plugins | index("other-v2") != null)' "$OC_CONFIG"
check jq -e '.theme == "custom" and .plugin == ["other-tui"]' "$OC_TUI_CONFIG"
check jq -e '.keybinds.leader == "ctrl+x" and .plugins == ["other-cli"]' "$OC_CLI_CONFIG"
check grep -qxF "$OC_TPS_PACKAGE" "$TMP/plugin-calls"
for file in "$OC_CONFIG" "$OC_TUI_CONFIG" "$OC_CLI_CONFIG"; do
    check compgen -G "$file.bak-*"
done
# Rerunning install must not register the plugin again, while t can explicitly repair it.
calls_before="$(wc -l < "$TMP/plugin-calls")"
check install_opencode
check test "$(wc -l < "$TMP/plugin-calls")" -eq "$calls_before"
check install_opencode tps <<< y
# shellcheck disable=SC2016 # jq expands $pkg, not the shell.
check jq -e --arg pkg "$OC_TPS_PACKAGE" '[.plugins[] | select(. == $pkg)] | length == 1' "$OC_CONFIG"

# Failed installation or missing registration must preserve legacy TPS config.
echo '{"plugin":["@mesaleh/opencode-tps"],"theme":"custom"}' > "$OC_TUI_CONFIG"
cp "$OC_TUI_CONFIG" "$TMP/legacy-before.json"
MOCK_FAIL_PLUGIN=true
reject install_opencode tps <<< y
check cmp "$TMP/legacy-before.json" "$OC_TUI_CONFIG"
MOCK_FAIL_PLUGIN=false
echo '{}' > "$OC_CONFIG"
MOCK_NO_REGISTRATION=true
reject install_opencode tps <<< y
check cmp "$TMP/legacy-before.json" "$OC_TUI_CONFIG"
MOCK_NO_REGISTRATION=false

# Invalid JSON must be rejected before invoking plugin add.
echo '{broken' > "$OC_CLI_CONFIG"
calls_before="$(wc -l < "$TMP/plugin-calls")"
reject install_opencode tps <<< y
check test "$(wc -l < "$TMP/plugin-calls")" -eq "$calls_before"
check cmp "$TMP/legacy-before.json" "$OC_TUI_CONFIG"

# A backup failure must stop both version changes and plugin installation.
echo '{}' > "$OC_CLI_CONFIG"
MOCK_FAIL_BACKUP=true
reject install_opencode tps <<< y
check test "$(wc -l < "$TMP/plugin-calls")" -eq "$calls_before"
check cmp "$TMP/legacy-before.json" "$OC_TUI_CONFIG"
echo '1.19.0' > "$MOCK_VERSION_FILE"
reject install_opencode <<< y
reject opencode_at_pinned_version
MOCK_FAIL_BACKUP=false

# The real CLI selects JSONC when present. Reject it before any install or config writes.
echo '{/* existing JSONC */ "plugins": ["@mesaleh/opencode-tps"]}' > "${OC_CONFIG}c"
cp "${OC_CONFIG}c" "$TMP/jsonc-before"
cp "$TMP/curl-args" "$TMP/curl-before"
reject install_opencode tps <<< y
check cmp "$TMP/jsonc-before" "${OC_CONFIG}c"
check cmp "$TMP/curl-before" "$TMP/curl-args"
check test "$(wc -l < "$TMP/plugin-calls")" -eq "$calls_before"

# Setup must address the same global config directory as the real OpenCode CLI.
(
    XDG_CONFIG_HOME="$TMP/xdg"
    source "$TEST_DIR/../setup.sh"
    check test "$OC_CONFIG" = "$TMP/xdg/opencode/opencode.json"
)

echo "PASS: OpenCode V2 installation, upgrade, plugin migration, repair, and failure paths"
