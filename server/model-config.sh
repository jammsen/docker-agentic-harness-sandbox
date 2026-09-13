#!/usr/bin/env bash
# model-config.sh — interactive editor for config/models.json, the real catalog of what this
# server serves (see README.md). Run directly on the server host (`./model-config.sh` from this
# directory) — unlike the client's wizard, this doesn't run inside a container, because you (the
# server operator) already have the network access to probe your own vLLM/llama.cpp/SGLang boxes
# directly. Same shape as ../sandbox-client/scripts/model-config.sh (add/edit/delete server, probe models,
# write & exit) but simpler: no roles, no aliases, no per-model vision/display-name questions —
# this server doesn't know or care about any of that (see the header of compose.yml). Every value
# this wizard asks for it tries to look up itself first (context window, real served id, root) —
# see probe_models() — so reconfiguring from "one big model" to "four small ones across two nodes"
# is mostly picking from a list, not retyping numbers.
#
# On write, offers to recreate catalog-render + litellm so the change actually takes effect —
# reasoning-normalizer re-reads models.json on its own (mtime watch), no restart needed there.
#
# Reasoning-effort tiers: any model can be exposed as several litellm model_names that all serve
# the SAME real backend id, each with a different baked-in reasoning_effort (`serves_as` +
# `reasoning_effort` fields — see scripts/render-litellm-config.sh) — picking a "model" in a client
# then really means picking an effort tier. Asked automatically when adding a model, or manage
# them later via edit server -> 5.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="$SCRIPT_DIR/config"
CFG="$CFG_DIR/models.json"
EXAMPLE="$CFG_DIR/models.example.json"
WORK=""
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
e()  { echo "$*"; }
ei() { echo "${DIM}$*${NC}"; }
ew() { echo "${YELLOW}$*${NC}"; }
ee() { echo "${RED}$*${NC}" >&2; }
es() { echo "${GREEN}$*${NC}"; }

command -v jq   >/dev/null || { ee ">>> jq is required (apt install jq / brew install jq)"; exit 1; }
command -v curl >/dev/null || { ee ">>> curl is required"; exit 1; }

# ---------------------------------------------------------------- scratch copy
load_work() {
    WORK="$(mktemp)"
    trap 'rm -f "$WORK"' EXIT
    if [[ -s "$CFG" ]]; then
        cp "$CFG" "$WORK"
    else
        echo '{"servers": {}}' > "$WORK"
    fi
    jq -e '.' "$WORK" >/dev/null 2>&1 || { ee ">>> $CFG is not valid JSON — fix or delete it and re-run"; exit 1; }
}

# ---------------------------------------------------------------- jq helpers
_j()  { jq "$@" "$WORK"; }
_ji() { local tmp; tmp="$(mktemp)"; jq "$@" "$WORK" > "$tmp" && mv "$tmp" "$WORK"; }
servers()       { _j -r '.servers // {} | keys[]'; }
server_url()    { local s="$1"; _j -r --arg s "$s" '.servers[$s].url // ""'; }
server_models() { local s="$1"; _j -r --arg s "$s" '.servers[$s].models // {} | keys[]'; }
model_field()   { local s="$1" m="$2" f="$3"; _j -r --arg s "$s" --arg m "$m" --arg f "$f" '.servers[$s].models[$m][$f] // ""'; }
all_models()    { local s; for s in $(servers); do local m; for m in $(server_models "$s"); do echo "$s/$m"; done; done; }
count_models()  { all_models | grep -c . || true; }

# Models sharing the same served id (real vLLM model), i.e. reasoning-effort variants of one
# another — everything whose `serves_as` matches this real id, or the entry AT that id itself.
sibling_variants() {
    local s="$1" real_id="$2"
    _j -r --arg s "$s" --arg id "$real_id" \
        '.servers[$s].models // {} | to_entries[] | select((.value.serves_as // .key) == $id) | .key'
}

# ---------------------------------------------------------------- probing
# probe_models <url> -> lines "id<TAB>max_model_len<TAB>root" ; returns 1 on failure.
# Straight GET <url>/models — this wizard runs on the server host, so it reaches your real vLLM
# boxes directly and gets their real metadata, no /model/info indirection needed (that trick is
# only for a CLIENT stuck behind this server's litellm — see ../ideas/model-catalog-configurator.md).
probe_models() {
    local url="$1" body
    body="$(curl -fsS -m "$PROBE_TIMEOUT" "$url/models" 2>/dev/null)" || return 1
    echo "$body" | jq -r '.data[]? | [.id, (.max_model_len // ""), (.root // "")] | @tsv' 2>/dev/null
}

# ---------------------------------------------------------------- display
overview() {
    local s n url i=0
    echo ""
    e "Server model catalog  ${DIM}($CFG)${NC}"
    echo ""
    echo "Servers"
    if [[ -z "$(servers)" ]]; then
        echo "  ${DIM}(none — this server has no models configured yet)${NC}"
    fi
    for s in $(servers); do
        i=$((i+1)); url="$(server_url "$s")"; n="$(server_models "$s" | grep -c . || true)"
        printf "  %d) %-14s %-36s %s model(s)\n" "$i" "$s" "$url" "$n"
        local m
        for m in $(server_models "$s"); do
            local ctx root serves effort tag
            ctx="$(model_field "$s" "$m" context)"; root="$(model_field "$s" "$m" root)"
            serves="$(model_field "$s" "$m" serves_as)"; effort="$(model_field "$s" "$m" reasoning_effort)"
            tag=""
            if [[ -n "$effort" ]]; then tag=" ${GREEN}[reasoning_effort=$effort, serves ${serves:-$m}]${NC}"; fi
            printf "     - %-38s ctx %-10s%s%s\n" "$m" "${ctx:-?}" "${root:+  ${DIM}$root${NC}}" "$tag"
        done
    done
    echo ""
}

# add_models_from_server <server>: probe, multi-select, store id+context+root (no other questions —
# this server doesn't need display names, vision flags, or max_tokens; that's client territory).
add_models_from_server() {
    local s="$1" url ids=() ctxs=() roots=() line
    url="$(server_url "$s")"
    ei "Looking up models on $url/models ..."
    local probed_out
    if probed_out="$(probe_models "$url")" && [[ -n "$probed_out" ]]; then
        while IFS=$'\t' read -r id ctx root; do
            [[ -n "$id" ]] || continue
            ids+=("$id"); ctxs+=("${ctx:-}"); roots+=("${root:-}")
        done <<< "$probed_out"
    else
        ew "Could not list models from $url (unreachable, or not an OpenAI-compatible /v1)."
        local ans; read -r -p "Enter model ids by hand instead? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || return 0
        local manual; read -r -p "Model ids (space-separated): " manual
        for id in $manual; do ids+=("$id"); ctxs+=(""); roots+=(""); done
    fi
    [[ ${#ids[@]} -gt 0 ]] || { ew "No models to add."; return 0; }

    echo ""; echo "Models on $s:"
    local i already
    for i in "${!ids[@]}"; do
        already=""; server_models "$s" | grep -Fx -- "${ids[$i]}" >/dev/null && already=" ${DIM}(already in catalog)${NC}"
        printf "  %d) %-40s ctx %s%s\n" "$((i+1))" "${ids[$i]}" "${ctxs[$i]:-?}" "$already"
    done
    echo ""
    local sel; read -r -p "Add which? (numbers like 1,3  |  all  |  empty = none): " sel
    [[ -n "$sel" ]] || return 0
    local chosen=()
    if [[ "${sel,,}" == "all" ]]; then chosen=("${!ids[@]}")
    else
        IFS=', ' read -ra parts <<< "$sel"
        local p
        for p in "${parts[@]}"; do
            [[ "$p" =~ ^[0-9]+$ ]] && [[ $p -ge 1 && $p -le ${#ids[@]} ]] && chosen+=("$((p-1))") || ew "ignoring '$p'"
        done
    fi
    for i in "${chosen[@]}"; do
        local id="${ids[$i]}" ctx="${ctxs[$i]}" root="${roots[$i]}"
        if [[ -z "$ctx" ]]; then
            while true; do
                read -r -p "  Context window for $id (tokens, required): " ctx
                [[ "$ctx" =~ ^[0-9]+$ ]] && break; ew "  number please"
            done
        fi
        add_model_with_effort_variants "$s" "$id" "$ctx" "$root"
    done
}

# store_model_entry <server> <alias> <ctx> <root> <serves_as|""> <reasoning_effort|"">: the one
# place that actually writes a models.json entry (single model or one reasoning-effort variant).
store_model_entry() {
    local s="$1" alias="$2" ctx="$3" root="$4" serves="$5" effort="$6"
    _ji --arg s "$s" --arg m "$alias" --arg c "$ctx" --arg r "$root" --arg sv "$serves" --arg e "$effort" \
        '.servers[$s].models[$m] = ({context: ($c|tonumber)}
            + (if $r  == "" then {} else {root: $r} end)
            + (if $sv == "" then {} else {serves_as: $sv} end)
            + (if $e  == "" then {} else {reasoning_effort: $e} end))'
}

# add_model_with_effort_variants <server> <real-id> <ctx> <root>: asks whether this model should be
# exposed as several reasoning-effort tiers (each a separate litellm model_name, all pointing at the
# SAME real served id via `serves_as` — see render-litellm-config.sh) or as one plain model.
add_model_with_effort_variants() {
    local s="$1" id="$2" ctx="$3" root="$4"
    echo ""
    read -r -p "  Reasoning-effort levels for $id, comma-separated (e.g. low,medium,high; empty = single model, no effort tiers): " levels
    if [[ -z "$levels" ]]; then
        store_model_entry "$s" "$id" "$ctx" "$root" "" ""
        es "  added $s/$id"
        return 0
    fi
    local lvl alias
    IFS=', ' read -ra levels_arr <<< "$levels"
    for lvl in "${levels_arr[@]}"; do
        [[ -n "$lvl" ]] || continue
        alias="${id}-${lvl}"
        if server_models "$s" | grep -Fx -- "$alias" >/dev/null; then
            ew "  $s/$alias already exists — skipped (edit or remove it first)"; continue
        fi
        store_model_entry "$s" "$alias" "$ctx" "$root" "$id" "$lvl"
        es "  added $s/$alias  (reasoning_effort=$lvl, serves $id)"
    done
}

# ---------------------------------------------------------------- menu actions
action_add_server() {
    local name url
    while true; do
        read -r -p "Server name (short, e.g. spark-a; empty = cancel): " name
        [[ -n "$name" ]] || return 0
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { ew "letters, digits, - and _ only"; continue; }
        if servers | grep -Fx -- "$name" >/dev/null; then ew "'$name' exists — use edit"; continue; fi
        break
    done
    while true; do
        read -r -p "OpenAI-compatible base URL incl. /v1 (e.g. http://10.0.0.25:8888/v1): " url
        [[ -n "$url" ]] || return 0
        url="${url%/}"
        [[ "$url" =~ ^https?:// ]] || { ew "must start with http:// or https://"; continue; }
        [[ "$url" == */v1 ]] || { ew "URL should end in /v1 (appending it)"; url="$url/v1"; }
        break
    done
    _ji --arg s "$name" --arg u "$url" '.servers[$s] = {url: $u, models: {}}'
    es "server $name added"
    add_models_from_server "$name"
}

action_edit_server() {
    local list=() s i
    for s in $(servers); do list+=("$s"); done
    [[ ${#list[@]} -gt 0 ]] || { ew "no servers yet"; return 0; }
    for i in "${!list[@]}"; do echo "  $((i+1))) ${list[$i]}  $(server_url "${list[$i]}")"; done
    local sel; read -r -p "Server number (empty = cancel): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 && $sel -le ${#list[@]} ]] || return 0
    s="${list[$((sel-1))]}"

    echo ""; echo "Edit $s ($(server_url "$s"))"
    echo "  1) look up models on the server / add more"
    echo "  2) remove a model"
    echo "  3) change URL (then looks up models on the new URL)"
    echo "  4) rename server"
    echo "  5) add/manage reasoning-effort variants for a model"
    local c; read -r -p "Choice (empty = back): " c
    case "$c" in
        1) add_models_from_server "$s" ;;
        2)
            local mlist=() m
            for m in $(server_models "$s"); do mlist+=("$m"); done
            [[ ${#mlist[@]} -gt 0 ]] || { ew "no models on $s"; return 0; }
            for i in "${!mlist[@]}"; do echo "  $((i+1))) ${mlist[$i]}"; done
            local msel; read -r -p "Remove which? (empty = cancel): " msel
            if [[ "$msel" =~ ^[0-9]+$ ]] && [[ $msel -ge 1 && $msel -le ${#mlist[@]} ]]; then
                m="${mlist[$((msel-1))]}"
                _ji --arg s "$s" --arg m "$m" 'del(.servers[$s].models[$m])'
                es "removed $s/$m"
            fi ;;
        3)
            local url; read -r -p "New base URL: " url; url="${url%/}"
            [[ -n "$url" ]] || return 0
            [[ "$url" =~ ^https?:// ]] || { ew "must start with http:// or https://"; return 0; }
            [[ "$url" == */v1 ]] || { ew "URL should end in /v1 (appending it)"; url="$url/v1"; }
            _ji --arg s "$s" --arg u "$url" '.servers[$s].url = $u'; es "url updated"
            local n; n="$(server_models "$s" | grep -c . || true)"
            [[ "$n" -gt 0 ]] && ew "$n model(s) are still listed for $s — verify they exist on the new server."
            add_models_from_server "$s" ;;
        4)
            local new
            while true; do
                read -r -p "New name for '$s' (empty = cancel): " new
                [[ -n "$new" ]] || return 0
                [[ "$new" =~ ^[a-zA-Z0-9_-]+$ ]] || { ew "letters, digits, - and _ only"; continue; }
                if servers | grep -Fx -- "$new" >/dev/null; then ew "'$new' exists"; continue; fi
                break
            done
            _ji --arg o "$s" --arg n "$new" '.servers = (.servers | to_entries | map(if .key == $o then .key = $n else . end) | from_entries)'
            es "renamed $s -> $new" ;;
        5) manage_effort_variants "$s" ;;
        *) return 0 ;;
    esac
}

# manage_effort_variants <server>: pick any existing catalog entry, treat its real served id
# (its `serves_as`, or itself if it's plain) as the base, show its current reasoning-effort
# siblings, and offer to add more tiers on top (context/root copied from the picked entry).
manage_effort_variants() {
    local s="$1" mlist=() m i
    for m in $(server_models "$s"); do mlist+=("$m"); done
    [[ ${#mlist[@]} -gt 0 ]] || { ew "no models on $s"; return 0; }
    for i in "${!mlist[@]}"; do echo "  $((i+1))) ${mlist[$i]}"; done
    local sel; read -r -p "Base which model on (number, empty = cancel): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 && $sel -le ${#mlist[@]} ]] || return 0
    local picked="${mlist[$((sel-1))]}" real_id ctx root
    real_id="$(model_field "$s" "$picked" serves_as)"; [[ -n "$real_id" ]] || real_id="$picked"
    ctx="$(model_field "$s" "$picked" context)"; root="$(model_field "$s" "$picked" root)"

    echo ""; echo "Real served model: $real_id  (ctx $ctx${root:+, $root})"
    local existing; existing="$(sibling_variants "$s" "$real_id")"
    if [[ -n "$existing" ]]; then
        echo "Existing entries for it:"
        echo "$existing" | while read -r e; do
            local eff; eff="$(model_field "$s" "$e" reasoning_effort)"
            printf "  - %-38s%s\n" "$e" "${eff:+  reasoning_effort=$eff}"
        done
    else
        echo "No variants yet — it's a single plain entry."
    fi
    add_model_with_effort_variants "$s" "$real_id" "$ctx" "$root"
}

action_delete_server() {
    local list=() s i
    for s in $(servers); do list+=("$s"); done
    [[ ${#list[@]} -gt 0 ]] || { ew "no servers yet"; return 0; }
    for i in "${!list[@]}"; do echo "  $((i+1))) ${list[$i]}  $(server_url "${list[$i]}")"; done
    local sel; read -r -p "Delete which server? (empty = cancel): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 && $sel -le ${#list[@]} ]] || return 0
    s="${list[$((sel-1))]}"
    read -r -p "Delete '$s' and all its models? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || return 0
    _ji --arg s "$s" 'del(.servers[$s])'
    es "deleted $s"
}

action_reset() {
    read -r -p "Reset the ENTIRE catalog? This empties every server/model. [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || return 0
    if [[ -s "$CFG" ]]; then
        cp "$CFG" "$CFG.bak-$(date +%Y%m%d%H%M%S)"
        es "backed up to $CFG.bak-*"
    fi
    echo '{"servers": {}}' > "$WORK"
    es "catalog reset (not written until you choose write & exit)"
}

restart_stack() {
    read -r -p "Render + restart litellm now so this takes effect? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || { ew "not restarted — run 'docker compose run --rm catalog-render && docker compose up -d --force-recreate litellm' when ready"; return 0; }
    # run --rm (not a normal `up` service): catalog-render is one-shot, this is the actual
    # --rm-equivalent for compose — see its comment in compose.yml for why it's not in depends_on.
    ( cd "$SCRIPT_DIR" && docker compose run --rm catalog-render && docker compose up -d --force-recreate litellm )
    es "restarted."

    ei "Waiting for litellm to come back up..."
    local i body=""
    for i in $(seq 1 20); do
        body="$(curl -fsS -m 3 http://localhost:4000/v1/models 2>/dev/null)" && [[ -n "$body" ]] && break
        sleep 1
    done
    if [[ -z "$body" ]]; then
        ew "litellm didn't answer within 20s — check yourself: curl http://localhost:4000/v1/models"
        return 0
    fi
    echo ""
    echo "GET http://localhost:4000/v1/models:"
    echo "$body" | jq '.'
}

action_write() {
    local n; n="$(count_models)"
    if [[ "$n" -eq 0 ]]; then
        ew "catalog has no models — litellm's render step needs at least one to start."
        read -r -p "Write an empty catalog anyway? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || return 0
    fi
    jq -e '.' "$WORK" >/dev/null || { ee ">>> internal error: scratch file is not valid JSON, not writing"; return 1; }
    cp "$WORK" "$CFG"
    es "wrote $CFG ($n model(s))"
    restart_stack
}

# ---------------------------------------------------------------- main menu
load_work
while true; do
    overview
    echo "  a) add server        e) edit server        d) delete server"
    echo "  R) RESET catalog      w) write & exit        q) quit without saving"
    read -r -p "Choice: " choice
    case "$choice" in
        a) action_add_server ;;
        e) action_edit_server ;;
        d) action_delete_server ;;
        R) action_reset ;;
        w) action_write; break ;;
        q) ew "quit without saving"; break ;;
        *) ew "unknown choice" ;;
    esac
done
