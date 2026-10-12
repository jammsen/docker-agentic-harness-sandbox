#!/usr/bin/env bash
# test-setup-helpers.sh — unit + write-path tests for the Hermes Agent and OpenCode model-catalog
# handling in ../setup.sh: the YAML status helpers, the providers_json jq program (vision flags +
# context/output limits), the fresh-config heredoc shapes, and both Hermes write paths (merge via
# `hermes config set` against a mock reproducing its documented set/get semantics, and the fresh
# heredoc). Everything the tests exercise is EXTRACTED FROM setup.sh at runtime, so the tests
# can't drift from the code they claim to cover.
#
# Needs: bash, jq, awk, python3 with PyYAML (for the YAML-shape assertions; those cases are
# skipped with a note when it's missing). No hermes install required — the write paths run
# against an embedded mock of `hermes config`.
set -euo pipefail
cd "$(dirname "$0")"
SETUP=../setup.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
chk() { # chk <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "PASS: $1"
    else fail=$((fail+1)); echo "FAIL: $1 (expected [$2] got [$3])"; fi
}
skip() { skipped=$((skipped+1)); echo "SKIP: $1 ($2)"; }

# ---------------------------------------------------------------- extract code under test
# Hermes YAML helpers: the block between their comment header and overview().
h_start="$(grep -n 'Hermes Agent (~/.hermes/config.yaml)' "$SETUP" | head -1 | cut -d: -f1)"
h_end="$(grep -n '^overview()' "$SETUP" | cut -d: -f1)"
[[ -n "$h_start" && -n "$h_end" ]] || { echo "FATAL: could not locate hermes helpers in $SETUP"; exit 1; }
sed -n "${h_start},$((h_end-1))p" "$SETUP" > "$TMP/helpers.sh"
# shellcheck disable=SC1090
source "$TMP/helpers.sh"

# OpenCode providers_json jq program: verbatim between its assignment and closing quote.
p_start="$(grep -n 'providers_json="' "$SETUP" | cut -d: -f1)"
p_end="$(awk -v s="$p_start" 'NR>s && /\x27\)"$/ {print NR; exit}' "$SETUP")"
[[ -n "$p_start" && -n "$p_end" ]] || { echo "FATAL: could not locate providers_json in $SETUP"; exit 1; }
sed -n "$((p_start+1)),$((p_end-1))p" "$SETUP" > "$TMP/providers.jq"
printf 'g\tm\tfalse\t1\t1\n' | jq -R -s --arg url x -f "$TMP/providers.jq" >/dev/null \
    || { echo "FATAL: extracted providers_json program does not compile"; exit 1; }
run_prog() { printf '%b' "$1" | jq -R -s --arg url "http://10.0.0.25:4000/v1" -f "$TMP/providers.jq"; }

# ---------------------------------------------------------------- hermes YAML helpers
cat > "$TMP/f1.yaml" <<'EOF'
model:
  default: GLM-5.3-Flash-EXL3-high
  provider: custom
  base_url: http://10.0.0.25:4000/v1
providers:
  custom:
    models:
      GLM-5.3-Flash-EXL3-high:
        supports_vision: true
mcp_servers:
  searxng:
    command: npx
    args: ["-y", "mcp-searxng"]
    env:
      SEARXNG_URL: "http://10.0.0.25:8080"
      SEARXNG_MAX_RESULTS: "10"
      SEARXNG_LITE_TOOLS: "true"
EOF
HERMES_CONFIG="$TMP/f1.yaml"
chk "f1 provider"    "custom"                   "$(hermes_model_field provider)"
chk "f1 default"     "GLM-5.3-Flash-EXL3-high"  "$(hermes_model_field default)"
chk "f1 base_url"    "http://10.0.0.25:4000/v1" "$(hermes_model_field base_url)"
chk "f1 configured"    "0" "$(hermes_configured >/dev/null; echo $?)"
chk "f1 vision"        "0" "$(hermes_vision_configured >/dev/null; echo $?)"
chk "f1 searxng"       "0" "$(hermes_searxng_configured >/dev/null; echo $?)"
chk "f1 searxng url" "http://10.0.0.25:8080"    "$(hermes_searxng_url)"
chk "f1 summary" "server http://10.0.0.25:4000/v1, model=GLM-5.3-Flash-EXL3-high, vision=yes, searxng=yes" "$(hermes_summary)"

# PyYAML-dumped shape (what `hermes config set` writes): single-quoted values, list-style args.
cat > "$TMP/f2.yaml" <<'EOF'
display:
  interface: tui
model:
  default: 'qwen3.6-35b'
  provider: custom
  base_url: 'http://localhost:4000/v1'
  api_key: dummy
agents:
  max_turns: 250
mcp_servers:
  searxng:
    command: npx
    args:
      - -y
      - mcp-searxng
    env:
      SEARXNG_URL: http://192.168.1.5:8080
EOF
HERMES_CONFIG="$TMP/f2.yaml"
chk "f2 default"    "qwen3.6-35b"              "$(hermes_model_field default)"
chk "f2 base_url"   "http://localhost:4000/v1" "$(hermes_model_field base_url)"
chk "f2 configured" "0" "$(hermes_configured >/dev/null; echo $?)"
chk "f2 vision(no)" "1" "$(hermes_vision_configured >/dev/null; echo $?)"
chk "f2 searxng url" "http://192.168.1.5:8080" "$(hermes_searxng_url)"

# User switched providers via `hermes model` → not configured (the script only manages custom).
cat > "$TMP/f3.yaml" <<'EOF'
model:
  default: claude-sonnet-4-6
  provider: openrouter
EOF
HERMES_CONFIG="$TMP/f3.yaml"
chk "f3 not configured" "1" "$(hermes_configured >/dev/null; echo $?)"

# Missing file: everything reports unconfigured, nothing errors.
HERMES_CONFIG="$TMP/nonexistent.yaml"
chk "f4 no url"         ""  "$(hermes_model_field base_url)"
chk "f4 not configured" "1" "$(hermes_configured >/dev/null; echo $?)"
chk "f4 vision"         "1" "$(hermes_vision_configured >/dev/null; echo $?)"
chk "f4 searxng"        "1" "$(hermes_searxng_configured >/dev/null; echo $?)"
chk "f4 searxng url"    ""  "$(hermes_searxng_url)"

# ---------------------------------------------------------------- providers_json (vision + limit)
# Case: two models, vision on/off, server reports context but no output window.
p="$(run_prog 'spark01\tGLM-5.3-Flash-EXL3-high\ttrue\t131072\t\nspark01\tqwen3.6-35b\tfalse\t131072\t\n')"
chk "glm limit.context"   "131072" "$(jq -r '.spark01.models["GLM-5.3-Flash-EXL3-high"].limit.context' <<<"$p")"
chk "glm limit.output"    "16384"  "$(jq -r '.spark01.models["GLM-5.3-Flash-EXL3-high"].limit.output' <<<"$p")"
chk "qwen limit.context"  "131072" "$(jq -r '.spark01.models["qwen3.6-35b"].limit.context' <<<"$p")"
chk "glm attachment kept" "true"   "$(jq -r '.spark01.models["GLM-5.3-Flash-EXL3-high"].attachment' <<<"$p")"
chk "qwen no attachment"  "false"  "$(jq -r '.spark01.models["qwen3.6-35b"].attachment // false' <<<"$p")"
chk "baseURL"             "http://10.0.0.25:4000/v1" "$(jq -r '.spark01.options.baseURL' <<<"$p")"

# Server-reported output window is used verbatim.
p2="$(run_prog 'spark01\tglm-x\ttrue\t200000\t65536\n')"
chk "reported output used" "65536"  "$(jq -r '.spark01.models["glm-x"].limit.output' <<<"$p2")"
chk "reported ctx used"    "200000" "$(jq -r '.spark01.models["glm-x"].limit.context' <<<"$p2")"

# Non-numeric / "-" context (unprobed field) → no limit key at all, schema stays clean.
p3="$(run_prog 'g\tm\tfalse\tnotanumber\t\n')"
chk "bad ctx → no limit" "false" "$(jq '.g.models.m | has("limit")' <<<"$p3")"
p4="$(run_prog 'g\tm\tfalse\t-\t-\n')"
chk "dash ctx → no limit" "false" "$(jq '.g.models.m | has("limit")' <<<"$p4")"

# ---------------------------------------------------------------- hermes fresh-config heredoc
# Exact shape setup.sh writes when ~/.hermes/config.yaml doesn't exist yet.
brain="GLM-5.3-Flash-EXL3-high"
cat > "$TMP/fresh.yaml" <<EOF
model:
  default: $brain
  provider: custom
  base_url: http://10.0.0.25:4000/v1
EOF
echo "  context_length: 131072" >> "$TMP/fresh.yaml"
cat >> "$TMP/fresh.yaml" <<EOF
providers:
  custom:
    models:
      $brain:
        supports_vision: true
EOF
if python3 -c "import yaml" >/dev/null 2>&1; then
    # HERMES_CONFIG is read dynamically by the sourced hermes_* helpers — shellcheck can't see that.
# shellcheck disable=SC2034
HERMES_CONFIG="$TMP/fresh.yaml"
    chk "fresh parses: default"    "$brain"  "$(hermes_model_field default)"
    chk "fresh parses: ctx length" "131072"  "$(hermes_model_field context_length)"
    python3 - "$TMP/fresh.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert isinstance(d["model"]["context_length"], int), "context_length must be a plain int (Hermes ignores '256K'-style strings)"
assert d["model"]["context_length"] == 131072
assert d["providers"]["custom"]["models"]["GLM-5.3-Flash-EXL3-high"]["supports_vision"] is True
PY
    chk "fresh: plain-int ctx + vision flag" "0" "$?"
else
    skip "fresh-config YAML assertions" "PyYAML not available"
fi

# ---------------------------------------------------------------- hermes write paths (mock e2e)
# Mock of `hermes config` reproducing the verified semantics of hermes_cli/config.py: set
# auto-coerces structured values via yaml.safe_load, creates intermediate dicts, writes YAML;
# get --json prints json.dumps; a missing key exits 1.
cat > "$TMP/hermes-mock" <<'MOCK'
#!/usr/bin/env python3
import sys, json, os, yaml
CONFIG = os.environ["MOCK_HERMES_CONFIG"]
def load():
    try:
        with open(CONFIG) as f: d = yaml.safe_load(f)
        return d if isinstance(d, dict) else {}
    except FileNotFoundError:
        return {}
def set_nested(d, key, value):
    parts = key.split(".")
    cur = d
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
        if not isinstance(cur, dict):
            raise SystemExit(f"✗ {p} is not a mapping")
    cur[parts[-1]] = value
def get_nested(d, key):
    cur = d
    for p in key.split("."):
        if not isinstance(cur, dict) or p not in cur: return None
        cur = cur[p]
    return cur
cmd, key = sys.argv[2], sys.argv[3]
if cmd == "get":
    val = get_nested(load(), key)
    if val is None:
        print(f"Config key not set: {key}", file=sys.stderr); sys.exit(1)
    print(json.dumps(val, ensure_ascii=False) if "--json" in sys.argv else val)
elif cmd == "set":
    raw = sys.argv[4].strip()
    if raw[:1] in "{[":
        try: value = yaml.safe_load(raw)
        except yaml.YAMLError: value = raw
    elif raw.lower() in ("true", "false"): value = raw.lower() == "true"
    else:
        # mirror _coerce_int/_coerce_float: numeric literals become numbers, everything
        # else stays a string (model ids like GLM-5.3-Flash-EXL3-high are not numeric)
        try: value = int(raw.replace("_", ""))
        except ValueError:
            try: value = float(raw)
            except ValueError: value = raw
    cfg = load()
    set_nested(cfg, key, value)
    with open(CONFIG, "w") as f: yaml.safe_dump(cfg, f, sort_keys=False)
MOCK
chmod +x "$TMP/hermes-mock"
hermes() { "$TMP/hermes-mock" "$@"; }
export MOCK_HERMES_CONFIG="$TMP/e2e.yaml"

# Path A — existing config.yaml: merge path. Model scalars rewritten, vision flag merged into
# existing models, unrelated sections survive.
cat > "$TMP/e2e.yaml" <<'EOF'
display:
  interface: tui
model:
  default: some-other-model
  provider: custom
  base_url: http://old:1234/v1
providers:
  custom:
    models:
      old-model:
        supports_vision: false
agents:
  max_turns: 250
EOF
hermes_vision=true
existing="$(hermes config get providers.custom --json 2>/dev/null || true)"
if [[ -n "$existing" ]] && echo "$existing" | jq -e 'type == "object"' >/dev/null 2>&1; then
    merged="$(jq --arg m "$brain" --argjson v "$hermes_vision" \
        '.models = ((.models // {}) + {($m): {supports_vision: $v}})' <<<"$existing")"
else
    merged="$(jq -n --arg m "$brain" --argjson v "$hermes_vision" '{models: {($m): {supports_vision: $v}}}')"
fi
hermes config set model.default "$brain"
hermes config set model.provider custom
hermes config set model.base_url "http://10.0.0.25:4000/v1"
hermes_ctx="131072"   # the probe-derived value, same shape setup.sh guards on
[[ "$hermes_ctx" =~ ^[0-9]+$ ]] && hermes config set model.context_length "$hermes_ctx"
hermes config set 'providers.custom' "$merged"
hermes config set 'mcp_servers.searxng' "$(jq -n --arg u "http://10.0.0.25:8080" \
    '{command: "npx", args: ["-y", "mcp-searxng"], env: {SEARXNG_URL: $u, SEARXNG_MAX_RESULTS: "10", SEARXNG_LITE_TOOLS: "true"}}')"
if python3 -c "import yaml" >/dev/null 2>&1; then
    python3 - "$TMP/e2e.yaml" "$brain" <<'PY'
import sys, yaml
d, brain = yaml.safe_load(open(sys.argv[1])), sys.argv[2]
assert d["model"]["default"] == brain and d["model"]["context_length"] == 131072
assert d["providers"]["custom"]["models"][brain]["supports_vision"] is True
assert d["providers"]["custom"]["models"]["old-model"]["supports_vision"] is False  # preserved
assert d["mcp_servers"]["searxng"]["env"]["SEARXNG_URL"] == "http://10.0.0.25:8080"
assert d["agents"]["max_turns"] == 250 and d["display"]["interface"] == "tui"       # preserved
PY
    chk "merge path: model+ctx+vision in, old entries and unrelated sections preserved" "0" "$?"
else
    skip "merge path YAML assertions" "PyYAML not available"
fi
unset MOCK_HERMES_CONFIG

# ---------------------------------------------------------------- results
echo ""
echo "RESULTS: $pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]]
