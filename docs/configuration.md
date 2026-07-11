---
sidebar_position: 3
title: Configuration
---

# Configuration

## Endpoint and model

Set the API endpoint once in the host environment:

```bash
export VLLM_URL=http://YOUR_VLLM_HOST:8000/v1
```

`compose.yml` passes this value to the sandbox, LiteLLM, and the experimental harness proxy. It does **not** rewrite the tool-specific model IDs. When changing models, update every active client configuration:

| File | Setting |
| --- | --- |
| `config/opencode/opencode.json` | provider `baseURL`, model key, default `model`, context and output limits |
| `config/omp/models.yml` | provider `baseUrl`, model `id`, context window and maximum tokens |
| `config/omp/config.yml` | each entry in `modelRoles` and context thresholds |
| `config/litellm-config.yaml` | each `hosted_vllm/<model-id>` mapping used by Claude aliases |
| `compose.yml` | `VLLM_MODEL` for the experimental `harness-proxy` service |

Use the exact ID returned by:

```bash
curl "$VLLM_URL/models" | jq
```

Keep configured context limits at or below the limit reported by the server, with enough headroom for the requested output.

## Tool selection

The `TOOLS` variable on the `sandbox` service controls the available menu and its order:

```yaml
environment:
  - TOOLS=claude,opencode,omp
```

The first entry is the default. `DEFAULT_TOOL` is normally empty and is filled by `start.sh --tool NAME` when requested.

## OpenCode

`config/opencode/` contains its provider configuration, global instructions, authentication placeholder, agents, commands, and skills. Compose mounts these paths read-only. Persistent application state is stored under `data/opencode/`.

## OMP

`config/omp/models.yml` defines providers and models, while `config/omp/config.yml` assigns model roles. `settings.json`, MCP configuration, and global instructions live in the same directory. OMP's main configuration and settings mounts are writable because OMP persists setup state.

## Claude Code and LiteLLM

`config/claude/settings.json` directs Claude Code to the local shim at `127.0.0.1:4001`. The shim forwards to LiteLLM, and `config/litellm-config.yaml` maps Claude model aliases onto the configured vLLM model. Dummy API keys satisfy client validation; they are not cloud credentials.

## Ports and storage

| Host port/path | Purpose |
| --- | --- |
| `1111/tcp` | WeTTY HTTPS terminal |
| `1112/tcp` | HTTPS image upload service |
| `3000/tcp` | workspace development server |
| `8080/tcp` | SearXNG (currently published by Compose) |
| `workspace/` | projects and uploaded images |
| `data/` | persistent tool sessions and state |

Change host-side port mappings in `compose.yml` if these ports conflict with other services.

## Context and output limits

Do not copy a model's marketing context size blindly. Query `/v1/models`, then configure a context limit no larger than the server actually exposes. Reserve enough room for output tokens and tool results.

OpenCode uses the `limit.context`, `limit.output`, and agent `maxTokens` values in `opencode.json`. OMP uses `contextWindow`, `maxTokens`, and the summarization thresholds in `config.yml`. If requests stall late in a long session, reduce the configured working context or move OMP's `summarizeAt` threshold earlier.

## Python build argument

The sandbox installs Python through `uv`. Change the version in the sandbox build arguments:

```yaml
services:
  sandbox:
    build:
      context: .
      args:
        PYTHON_VERSION: "3.12"
```

Then rebuild the affected layers:

```bash
./start.sh --no-cache
```

Choose a version supported by `uv`. Changing the argument invalidates the Docker cache from the Python installation layer onward.
