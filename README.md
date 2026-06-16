# A hardened Docker harness for agentic coding tools

Run agentic coding tools — OpenCode, OMP, and more — inside a single hardened, non-root Docker container. Connect to a self-hosted vLLM inference server or any OpenAI-compatible API. No cloud API keys required.

---

## Table of Contents

- [A hardened Docker harness for agentic coding tools](#a-hardened-docker-harness-for-agentic-coding-tools)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Directory Structure](#directory-structure)
  - [Get, Build \& Run](#get-build--run)
  - [Verify Everything Works](#verify-everything-works)
  - [Usage Tips](#usage-tips)
    - [Working with files](#working-with-files)
    - [Resetting sandbox state](#resetting-sandbox-state)
    - [Tool selection](#tool-selection)
    - [Modes](#modes)
    - [Context window awareness](#context-window-awareness)
  - [Troubleshooting](#troubleshooting)
  - [Security Notes](#security-notes)
  - [Included Software](#included-software)
  - [Build Argument](#build-argument)
  - [Using Tools and Skills](#using-tools-and-skills)
    - [Commands](#commands)
    - [Skills](#skills)


## Prerequisites

- Docker + Docker Compose installed on your machine
- Access to a running vLLM server exposing an OpenAI-compatible API (e.g. `http://10.0.0.13:8000`)
- Your vLLM server must have the model loaded and `/v1/models` responding

> **How this works:** The agent tools running inside the container are clients to your external vLLM server. They have no direct access to the model weights — all inference goes through the API endpoint. If a tool ever needs to identify which model it is using, it must look it up via the API or a web search based on the model ID configured in `config/opencode.json` / `config/omp-models.yml`.

Verify your vLLM is reachable before starting:

```bash
curl http://10.0.0.13:8000/v1/models
```

You should see your model ID in the response (e.g. `qwen3.6-35b`).

Use the exact `"id"` value from the response — e.g. `qwen3.6-35b`.

**Finding your context size:**
The `max_model_len` field in the `/v1/models` response is your context limit. Use that value for `"context"`.

---

## Directory Structure

After cloning, the repository already contains this layout:

```
docker-agentic-harness-sandbox/
├── Dockerfile
├── compose.yml
├── start.sh
├── config/
│   ├── opencode.json       ← opencode provider and agent config (mounted read-only)
│   ├── AGENTS.md           ← global sandbox rules for opencode (mounted read-only)
│   ├── auth.json           ← provider auth tokens (mounted read-only) — edit before use
│   ├── omp-AGENTS.md       ← sandbox rules for omp (mounted read-only)
│   ├── omp-config.yml      ← OMP model role assignments (mounted read-only)
│   └── omp-models.yml      ← OMP provider and model definitions (mounted read-only)
├── data/               ← tool session state, persisted across runs
├── scripts/            ← maintenance scripts (e.g. reset-sandbox.sh)
├── .opencode/          ← global sandbox commands and skills (mounted read-only)
└── workspace/          ← put your code projects here
```

---

## Get, Build & Run

```bash
# Get the code
git clone git@github.com:jammsen/docker-agentic-harness-sandbox.git

# Build and launch
./start.sh

# Force a full rebuild (no layer cache) — useful when the base image digest has been updated
./start.sh --no-cache
```

On first launch the container prompts you to select a tool. After selection the chosen tool opens its TUI. For OpenCode, press `/` to open the command palette.

---

## Verify Everything Works

### OpenCode

Inside the OpenCode TUI:

1. Type `/model` — your model should appear under your provider name with an orange dot
2. Type `hello, what model are you?` — the response should mention your model ID
3. Check the status bar at the bottom — it should show your configured model, for example `Qwen3.6 35B A3B · vLLM`
4. Check the right panel — `$0.00 spent` confirms no cloud API is being used

### OMP

Inside the OMP session:

1. Run `omp status` or check the startup output — your provider and model should be listed
2. Send a message like `hello, what model are you?` — the response should mention your model ID
3. Confirm the provider is `vllm` and the response is served locally

---

## Usage Tips

### Working with files

Drop files into `./workspace/` on your host. They appear at `/home/agent/workspace/` inside the container. The active tool treats this directory as its working root; tool configs live under `/home/agent/.config/` and `/home/agent/.omp/` respectively.

```bash
# Copy a project into the sandbox
cp -r ~/myproject ./workspace/myproject
```

### Resetting sandbox state

Use `scripts/reset-sandbox.sh` only when you intentionally want to remove generated local state from `./workspace/` and `./data/`. It preserves the `.gitkeep` placeholders and requires typing `Yes, do as I say!` before deleting anything.

### Tool selection

At startup the container presents a numbered menu. **Only one tool runs at a time** — select it and the others stay idle until the next container start.

The menu order and default are controlled by the `TOOLS` env var, defaulting to the value baked into the image. Override it in `compose.yml`:

```yaml
environment:
  - TOOLS=opencode,omp   # first entry = default
```

Change the order or remove entries to customise what appears. The entrypoint validates each name against installed binaries and skips any that are missing.

To skip the menu entirely, use the `--tool` flag in `start.sh`:

```bash
./start.sh --tool omp
./start.sh --tool opencode
```

This passes `DEFAULT_TOOL` into the container and goes straight to that tool. Useful for scripting or when you always use the same tool.

### Modes (OpenCode)

OpenCode has two interaction modes:

| Mode  | Shortcut | Token overhead | Best for                               |
| ----- | -------- | -------------- | -------------------------------------- |
| Build | default  | ~10k tokens    | Agentic file editing, multi-step tasks |
| Ask   | `tab`    | ~3-5k tokens   | Questions, code review, explanations   |

With a 32k context limit, **Ask mode** leaves significantly more room for your actual code and conversation.

OMP does not have a comparable mode concept — it operates as a single interactive session.

### Context window awareness

For OpenCode, the status bar shows `X tokens (Y% used)`. Build mode consumes ~10,000 tokens just for the system prompt before you type anything. For large codebases, open only the files you need or use Ask mode.

---

## Troubleshooting

**Config not loading / provider picker appears on every launch**

```bash
docker compose run --rm --entrypoint bash sandbox -c \
  "cat /home/agent/.config/opencode/opencode.json"
```

If this returns an error, check that `docker compose` is run from the same directory as `compose.yml` and that `./config/opencode.json` exists.

**`GID already exists` error during build**

Ubuntu 26.04 ships with a default user at UID/GID 1000. The Dockerfile handles this by renaming the existing user instead of creating a new one. Ensure you are using the Dockerfile exactly as provided above.

**Model not responding / timeout**

```bash
# Test vLLM connectivity from inside the container
docker compose run --rm --entrypoint bash sandbox -c \
  "curl -s http://YOUR_VLLM_IP:8000/v1/models"
```

If this fails, your vLLM IP is unreachable from the container. Use the actual host IP — not `localhost`.

**[OpenCode] Tool calling loops or model halts mid-task**

Some local models can struggle with long agentic tool-use loops. Mitigations:

- Prefer **Ask mode** for questions and code review that don't require file editing
- For Build mode, give explicit step-by-step instructions rather than open-ended goals
- Keep tasks scoped to one file or one function at a time

---

## Security Notes

The container starts as root to handle setup (creating the user, fixing file ownership on mounted volumes), then permanently drops to an unprivileged user via `gosu` before your session begins. There is no way back to root after that point.

**Restrictions in place:**

- **Pinned base image digest** — the `FROM` line in the Dockerfile references `ubuntu:26.04` by its exact SHA-256 digest. This ensures every build uses bit-for-bit the same base layer regardless of what the upstream tag points to, preventing supply-chain attacks via tag mutation.
- **`umask 0027`** — files created by the entrypoint are not world-readable by default. Only the owning user and group can read them; others have no access.
- **PUID/PGID validation** — the entrypoint rejects non-positive-integer values immediately at startup, preventing misconfigured or injected UID/GID values from silently running the app as root.
- **`no-new-privileges`** — once the container drops to the unprivileged user, no process inside the container can ever gain more permissions, even if it tries to run a `sudo` binary or a binary with special file capabilities. The kernel enforces this hard, before any code in such a binary even runs.
- **`cap_drop: ALL`** — Linux capabilities are fine-grained units of root power (e.g. "change file ownership", "bind to privileged ports", "load kernel modules"). By default Docker grants containers a subset of these even without full root. Dropping all of them removes every one of those powers.
- **`cap_add: CHOWN, SETUID, SETGID, DAC_OVERRIDE`** — only the four capabilities the entrypoint actually needs for its setup phase are added back. Once `gosu` drops to the non-root user, the kernel automatically clears the effective capability set on the UID transition, and `no-new-privileges` blocks any path to reclaiming them.
- **`PUID` / `PGID`** — the in-container user is created at runtime with the same UID/GID as your host user. This ensures bind-mounted files in `./workspace` and `./data` have correct ownership on both sides of the mount.
- Bridge networking only — isolated from the host network
- Writable filesystem access is limited to `./workspace` and `./data` on the host. Config, commands, skills, and auth are mounted read-only.

The model runs entirely on your local vLLM server. No data leaves your network.

## Included Software

All runtimes and tools are installed at **build time** under the `agent` user — the container starts instantly with no downloads at startup.

| Software | How installed | Purpose |
| --- | --- | --- |
| `opencode` | `opencode.ai/install` | Agentic coding tool with TUI |
| `omp` | `omp.sh/install` | Agentic coding tool (CLI) |
| Node.js + npm | apt | Available in the workspace for Node.js projects |
| Python (`uv`) | `astral.sh/uv` | General scripting in the workspace |
| Rust (`rustup`) | `sh.rustup.rs` | General building in the workspace |
| `ripgrep` | apt | File search used by agent tools |
| `tzdata` | apt | Europe/Berlin timestamps |
| `git` | apt | Version control inside the container |
| `gosu` | apt | Privilege drop from root to `agent` user |

Tool binaries are on `PATH` and their data directories (`CARGO_HOME`, `RUSTUP_HOME`) are pinned via environment variables so they survive the `HOME` redirect used to route session state to the mounted workspace.

## Build Argument

The only build argument is the Python version. Change it in `compose.yml` before building:

```yaml
# compose.yml
services:
  sandbox:
    build:
      context: .
      args:
        PYTHON_VERSION: "3.12"   # change to any version supported by uv
```

Then rebuild:

```bash
./start.sh --no-cache
```

---

## Using Tools and Skills

### Commands

Sandbox-wide commands and skills are mounted globally:

```yaml
- ./config/AGENTS.md:/home/agent/.config/opencode/AGENTS.md:ro
- ./.opencode/commands:/home/agent/.config/opencode/commands:ro
- ./.opencode/skills:/home/agent/.config/opencode/skills:ro
```

Note: `./config/AGENTS.md` is intentionally separate from `./config/opencode.json` — the AGENTS.md path is referenced in the opencode system prompt and must be mounted at its exact target location.

This makes the commands available regardless of which project under `./workspace/` you open. Project-specific commands, skills, and `AGENTS.md` files can still live inside the project directory.

`AGENTS.md` is intentionally short: it gives global orientation. Repeatable process requirements live directly in the commands, because local models follow concrete command workflows more reliably than broad standing instructions.

Available sandbox commands:

- `/refactor-audit <target>` — analyze refactor opportunities without editing files
- `/refactor-apply <approved scope>` — apply one focused approved refactor, verify it, and update `WORKLOG.md`
- `/git-commit` — review, document, and commit approved changes using Conventional Commits

### Skills

Skills are reusable on-demand capabilities for an agent. They use one directory per skill with a mandatory `SKILL.md`.

The included `write-worklog` skill provides a structured `WORKLOG.md` entry format for ad-hoc tasks. Command-driven workflows inline their own worklog format so they do not depend on automatic skill selection.
