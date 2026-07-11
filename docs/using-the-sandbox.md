---
sidebar_position: 4
title: Using the sandbox
---

# Using the sandbox

## Projects and sessions

Place projects under `workspace/` on the host. They appear at `/home/agent/workspace/` inside the sandbox. Each browser connection can create a GNU screen session or attach to an existing one; closing the browser detaches without stopping the agent.

## Upload an image

Open `https://HOST:1112`, then paste, drag, or select a PNG, JPEG, GIF, or WebP image. Uploaded files are stored under `workspace/uploads/`, and the page displays the in-container path to give the agent. The maximum upload size is 50 MB.

For Claude Code vision requests, ask Claude to read that path. The local shim moves images out of Anthropic tool-result blocks before LiteLLM translates the request. The selected backend model must support vision through chat completions.

## Run a one-shot task

Use the wrapper so the process drops from root to the unprivileged `agent` user:

```bash
docker exec agentic-harness-sandbox agent-task "Summarise this project"

echo "$LOGS" | docker exec -i agentic-harness-sandbox \
  agent-task "Identify the repeating error"

docker exec agentic-harness-sandbox \
  agent-task "Plan a refactor" --permission-mode plan
```

Do not replace this with a direct `docker exec ... claude` invocation, which inherits the container entrypoint user.

## Reset local state

```bash
scripts/reset-sandbox.sh
```

The script removes generated content from `workspace/` and `data/`, preserves `.gitkeep` files, and requires an exact interactive confirmation. `--destroy` skips the prompt and should only be used deliberately.
