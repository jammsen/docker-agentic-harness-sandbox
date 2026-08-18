# Idea: model catalog + configurator (pick brain / vision like we pick the tool)

Status: idea, 2026-08-18. Do on a fresh branch after `feat/bifrost-replacement-test` is merged.

## Problem

Model config is one flat env contract (`x-model-env` in `compose.yml`, values from `.env`):

```
MODEL_URL / MODEL_ID / MODEL_NAME / MODEL_CONTEXT / MODEL_MAX_TOKENS / MODEL_VISION   = brain
VISION_MODEL_URL / _ID / _NAME / _CONTEXT / _MAX_TOKENS                               = eyes
```

That was the right first step (`ideas/dynamic-models.md`), but it has two practical problems:

1. **The knobs for one model are split across 5-6 loose variables** and nothing ties them
   together. Swapping the Spark today left `MODEL_URL` pointing at the new box while `MODEL_ID`
   still named the old build (`deepseek-v4-flash-dspark` vs served `deepseek-v4-flash-0731`) —
   LiteLLM would 404 every request. The id, context and vision flag *belong to* the URL; the
   env layout lets them drift apart.
2. **Switching models means editing `.env`** by hand, remembering which 5 vars to change, and
   nobody else can see which candidates exist. There is no "menu" of known-good models the way
   there is one for tools (`TOOLS=claude,opencode,omp` → `agent-session.sh` picker in the
   browser, `DEFAULT_TOOL` to skip it).

Goal: a **catalog** of known models in a mounted repo config file, and a **selection** step
that picks one brain and one vision model from it — the same "list + default + picker" shape
the tool menu already has.

## Where the choice can take effect (the constraint that shapes the design)

The brain path is `Claude Code → claude-shim → LiteLLM → [headroom] → reasoning-normalizer → vLLM`.
Three of those are *separate containers* whose upstream is fixed at their own start:

| component | what is fixed at container start | how |
|---|---|---|
| litellm | `model_list` (ids + `api_base`) | `sh -c` wrapper seds `__MODEL_ID__` etc. into `config/litellm-config.yaml`; `api_base` via `os.environ/MODEL_URL` |
| reasoning-normalizer | `VLLM_UPSTREAM` (single host:port) | env |
| headroom (opt-in) | `OPENAI_TARGET_API_URL` (single) | env |
| sandbox | opencode/omp configs (`envsubst` in `includes/config.sh:render_tool_templates`), claude-shim (`MODEL_VISION`, `MODEL_ID`, `VISION_MODEL_ID` read once at start) | entrypoint |

So a picker that runs *inside a browser session* can only change per-session things
(Claude Code's `ANTHROPIC_DEFAULT_*_MODEL`, which litellm alias to hit) — it cannot repoint
litellm/normalizer/headroom. That splits the idea into two phases; phase 1 is the one worth
doing now.

## Phase 1 — catalog + compose-time selection (the deliverable)

### `config/models.yml` (mounted `:ro`, replaces the model vars in `.env`)

```yaml
# Known-good models. One entry = everything the stack needs to know about one served model.
# id must be the exact id from GET <url>/models; context = max_model_len from the same call.
models:
  deepseek-v4-flash-0731:
    url: http://10.0.0.25:8888/v1
    id: deepseek-v4-flash-0731
    name: "DeepSeek V4 Flash 0731"
    context: 1000000
    max_tokens: 16384
    vision: false
    fuses_reasoning: true      # both-field deltas -> needs the reasoning-normalizer (see deepseek-thinking-block-bug.md)
  qwen3.6-35b:
    url: http://10.0.0.13:8000/v1
    id: qwen3.6-35b
    name: "Qwen3.6 35B A3B"
    context: 120000
    max_tokens: 16384
    vision: true

# Roles. Selection = one key per role; `vision` may equal `brain` (single-model setup).
default:
  brain: deepseek-v4-flash-0731
  vision: qwen3.6-35b
```

`.env` keeps only overrides: `BRAIN=qwen3.6-35b` / `VISION=...` (empty = `default:` from the
file). Everything below the selection stays exactly as it is — the catalog is *rendered into
the existing `MODEL_*` / `VISION_MODEL_*` contract*, so litellm template, opencode/omp templates,
claude-shim, normalizer, headroom, README's "one env contract" story all keep working unchanged.

### Render step: one small script, one place

`scripts/render-model-env.sh` (host side, POSIX sh + `yq` **or** pure python — no new runtime
in the image; the sandbox already ships python 3.13, the host may not have `yq`):

- input: `config/models.yml` + `BRAIN`/`VISION` env
- output: the `MODEL_*` / `VISION_MODEL_*` lines → written to `.env.models` (generated,
  gitignored) which compose loads via `env_file:` — or exported into the shell for
  `docker compose up`
- validation: unknown key → error listing available keys (same "not available. Available: …"
  UX as `DEFAULT_TOOL` in `agent-session.sh`); optional `--probe` does `GET url/models` and
  fails loudly if `id` isn't served (would have caught the Spark-swap drift immediately).

Rendering *outside* the containers is deliberate: `x-model-env` values are needed by **four**
services (sandbox, litellm, normalizer, headroom) at compose evaluation time, so the expansion
has to happen before/at `compose up`, not in one container's entrypoint. Keep the existing
per-service rendering as-is; only the *source* of the values moves from hand-edited `.env` to
catalog+selection.

Alternative considered: a tiny `model-config` init service that renders and the others
`depends_on` it — rejected, compose interpolation of `${MODEL_URL}` in `x-model-env` happens
before any container runs, so a runtime service can't feed it. `env_file: .env.models` is the
compose-native answer.

### UX

```
BRAIN=qwen3.6-35b docker compose up -d           # pick from catalog for this deployment
docker compose up -d                              # defaults from config/models.yml
scripts/render-model-env.sh --list                # print catalog: key, name, url, vision, context
scripts/render-model-env.sh --probe               # verify every catalog entry is actually served
```

Also fixes an existing footgun: `x-model-env` in `compose.yml` currently carries hardcoded
fallbacks (`10.0.0.25`, `deepseek-v4-flash-dspark`) that silently apply when `.env` is missing.
With the catalog those defaults live in ONE reviewed file with names attached.

### Touch list (phase 1)

- `config/models.yml` (new), `scripts/render-model-env.sh` (new), `.gitignore` (+`.env.models`)
- `compose.yml`: `env_file: [.env, .env.models]` (or keep `x-model-env` but drop hardcoded
  fallbacks and let render fail loudly), comment header pointing to the catalog
- `.env.example`: model block → `BRAIN=` / `VISION=` two-liner
- `README.md` "model configuration" section, `ideas/dynamic-models.md` "superseded by" note
- `includes/model.sh:setup_model_env` unchanged (its `:?` guards become the safety net)
- optional: `tests/test-render-model-env.sh` (unknown key, defaults, vision==brain, probe)

## Phase 2 — per-session picker (follow-up issue, only if we actually switch brains mid-day)

Prereqs, each a real change:

1. litellm serves **every** catalog entry as an alias (`model_list` generated from
   `models.yml`, not the fixed 9-entry template) — then `brain`/`vision`/`opus`/`sonnet` become
   *pointers* the session can move.
2. reasoning-normalizer routes per request instead of one `VLLM_UPSTREAM` — e.g. litellm
   `api_base: http://normalizer:4002/u/10.0.0.25:8888/v1`, normalizer parses the target out of
   the path (its splitter is upstream-agnostic already). Same for headroom's target, or accept
   that headroom is brain-only.
3. `agent-session.sh` grows a "brain / eyes" menu next to the tool menu, sets
   `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` per session. **Caveat:** opencode/omp configs
   live in the shared `/home/agent`, so two concurrent browser sessions choosing different
   brains would fight — per-session only cleanly works for Claude Code unless those configs
   move to per-session dirs (`XDG_CONFIG_HOME` per tmux session).
4. claude-shim's `VISION_SIDE`/`BRAIN_ID` become per-request (they only exist for logging + the
   text-only-brain image reroute; the reroute needs `vision:` per model from the catalog).

Not started; phase 1 makes all of it possible without redoing anything.

## Non-goals

- No web UI. The "configurator" is a YAML file + a `--list/--probe` script + (phase 2) the
  same numbered terminal menu as the tool picker. Consistent with the palworld-style thin
  manager + `includes/*.sh` shape of the repo.
- No auto-discovery of models from vLLM. `--probe` verifies the catalog; it doesn't invent
  entries (context/max_tokens/vision/fuses_reasoning are curated facts, not discoverable ones).
