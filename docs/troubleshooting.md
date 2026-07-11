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

If OpenCode repeatedly shows the provider picker, verify both its mounted configuration and authentication placeholder:

```bash
docker exec agentic-harness-sandbox ls -l \
  /home/agent/.config/opencode/opencode.json \
  /home/agent/.local/share/opencode/auth.json
```

## Build reports `GID already exists`

Ubuntu's base image includes a user and group at ID 1000. The repository Dockerfile renames that account to `agent` instead of blindly creating another one. Make sure the build uses the repository Dockerfile and that local changes have not replaced the `usermod` and `groupmod` step.

## Tool calling loops or stops mid-task

Local models vary in their ability to sustain long tool-use sequences. Try the following:

- Use OpenCode Ask mode for questions and reviews that do not require edits.
- Break the request into one file or one concrete change at a time.
- Reduce context thresholds when failures appear only in long sessions.
- Verify that the model supports the tool-call format emitted by the selected client.
- Start a new screen session to distinguish model behavior from a heavily loaded transcript.

## A development server is unreachable

The sandbox publishes port 3000. Ensure the application listens on `0.0.0.0`, not only `127.0.0.1` inside the container:

```bash
npm run dev -- --host 0.0.0.0
```

For applications on another port, add an explicit mapping to the `sandbox` service in `compose.yml` and recreate it.

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
