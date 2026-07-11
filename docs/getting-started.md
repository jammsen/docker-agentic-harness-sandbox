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

Inside OpenCode, run `/model`. In OMP, run `omp status`. For Claude Code, send a short prompt and inspect `docker compose logs litellm` if the request fails.

## Stop the stack

```bash
docker compose down
```
