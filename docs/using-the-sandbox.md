---
sidebar_position: 4
title: Using the sandbox
---

# Using the sandbox

## Projects and sessions

Place projects under `workspace/` on the host. They appear at `/home/agent/workspace/` inside the sandbox. Each browser connection can create a GNU screen session or attach to an existing one; closing the browser detaches without stopping the agent.

```bash
cp -r ~/myproject ./workspace/myproject
```

On connection, the session picker lists existing sessions and an option to create a new one. Selecting an existing session uses multiattach mode, so desktop and mobile browser tabs can view the same running agent simultaneously. Stale sessions are cleaned with `screen -wipe` before the picker is shown. Invalid selections re-open the prompt.

Only one agent tool runs in each screen session. Create separate sessions when you want to use multiple tools concurrently. The tool menu appears when a new screen session starts; reattaching returns directly to the already-running tool.

### Why there are two session scripts

`entrypoint.sh` runs once as root when the container starts. It validates UID/GID settings, repairs mounted-file ownership, synchronizes configuration, and supervises the upload and shim processes.

`agent-session.sh` runs for each browser connection. It immediately drops to the `agent` user, then handles screen attachment and tool selection. Keeping these lifetimes separate ensures no agent tool starts before the one-time setup is complete.

## Tool modes and context usage

| Tool | Mode | Shortcut | Typical initial overhead | Best suited to |
| --- | --- | --- | --- | --- |
| OpenCode | Build | default | about 10k tokens | multi-step editing and tool use |
| OpenCode | Ask | `Tab` | about 3–5k tokens | questions, reviews, and explanations |
| Claude Code | Default | — | can exceed 20k tokens | editing and tool-driven tasks |
| OMP | Default | — | not publicly documented | general interactive tasks |

These figures are approximate and change with tool releases, MCP servers, instructions, and available tools. For smaller context windows, prefer OpenCode Ask mode for read-only questions and keep editing tasks narrowly scoped. Long transcripts, large files, and tool results all consume the same context budget.

## Upload an image

Open `https://HOST:1112`, then paste, drag, or select a PNG, JPEG, GIF, or WebP image. Uploaded files are stored under `workspace/uploads/`, and the page displays the in-container path to give the agent. The maximum upload size is 50 MB.

For Claude Code vision requests, ask Claude to read that path. The local shim moves images out of Anthropic tool-result blocks before LiteLLM translates the request. The selected backend model must support vision through chat completions.

Do not ask the model to read manually generated base64 text. Give Claude Code the file path so its Read tool creates a real image content block.

Test the backend independently when image descriptions are generic or incorrect:

```bash
curl "$VLLM_URL/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "YOUR_MODEL_ID",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "image_url", "image_url": {"url": "https://example.com/test-image.jpg"}},
        {"type": "text", "text": "Describe this image."}
      ]
    }]
  }'
```

Use a test image URL you control. A successful text-only request does not prove that the model or its chat template supports vision.

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
