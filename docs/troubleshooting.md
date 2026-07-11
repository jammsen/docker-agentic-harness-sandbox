---
sidebar_position: 7
title: Troubleshooting
---

# Troubleshooting

## The model does not respond

Confirm the endpoint includes `/v1`, then test it from both host and sandbox:

```bash
curl "$VLLM_URL/models"
docker exec agentic-harness-sandbox curl -s http://YOUR_VLLM_HOST:8000/v1/models
```

Do not use `localhost` for a model server running on the Docker host. Use a routable host or LAN address.

## The browser says “Session ended”

```bash
docker exec agentic-harness-sandbox \
  su -s /bin/bash agent -c "screen -wipe"
```

Reconnect after stale sessions are removed.

## Configuration is not loaded

Run Compose from the repository root and verify the mounted file:

```bash
docker exec agentic-harness-sandbox \
  cat /home/agent/.config/opencode/opencode.json
```

After changing tool or proxy configuration, rebuild and recreate the relevant services.

## Images are ignored

Confirm the model is vision-capable over `/v1/chat/completions`, the uploaded file exists in `/home/agent/workspace/uploads/`, and the Claude shim and LiteLLM services are healthy:

```bash
docker compose logs sandbox litellm
```

## Inspect and restart

```bash
docker compose ps
docker compose logs -f SERVICE
docker compose restart SERVICE
```
