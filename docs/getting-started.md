---
sidebar_position: 2
title: Getting started
---

# Getting started

## Prerequisites

- Docker Engine or Docker Desktop with Docker Compose
- Git
- A reachable vLLM or OpenAI-compatible server with a model already loaded

The default endpoint in `compose.yml` is site-specific. Set `VLLM_URL` for your environment and include the `/v1` suffix.

## Install and start

```bash
git clone git@github.com:jammsen/docker-agentic-harness-sandbox.git
cd docker-agentic-harness-sandbox

export VLLM_URL=http://192.168.1.50:8000/v1
curl "$VLLM_URL/models"

./start.sh
```

`start.sh` builds the images, stops an existing sandbox container when necessary, and starts the stack in the background. Use `./start.sh --no-cache` for a clean rebuild.

Open `https://HOST:1111` and accept the self-signed certificate warning. The terminal asks you to create or reattach a GNU screen session, then select Claude Code, OpenCode, or OMP.

To choose a tool automatically for every new browser connection:

```bash
./start.sh --tool claude
./start.sh --tool opencode
./start.sh --tool omp
```

## Verify the stack

```bash
docker compose ps
docker compose logs -f
```

### OpenCode

Inside the OpenCode TUI:

1. Run `/model` and confirm the configured model appears under the `vllm` provider.
2. Ask `What model are you?` and compare the response with the ID returned by `/v1/models`.
3. Check that the status bar shows the expected model.
4. Confirm the spending indicator remains `$0.00`; the configured provider should not call a paid cloud API.

### OMP

1. Run `omp status` and confirm the `vllm` provider and expected model.
2. Send a short prompt and verify that it completes.
3. If it does not, compare `config/omp/models.yml` with the server's `/v1/models` response.

### Claude Code

Send a short prompt, then inspect the translation services if it fails:

```bash
docker compose logs sandbox litellm
```

Claude Code uses Anthropic model aliases locally, so its displayed alias can differ from the backend vLLM model ID. `config/litellm-config.yaml` is the authoritative mapping.

## Stop the stack

```bash
docker compose down
```
