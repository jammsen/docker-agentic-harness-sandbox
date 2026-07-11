---
sidebar_position: 6
title: Tools, commands, and skills
---

# Tools, commands, and skills

## Included software

The image installs its runtimes and tools at build time, so normal container startup does not download them.

| Software | Installation | Purpose |
| --- | --- | --- |
| Claude Code | official install script | Anthropic-compatible coding CLI routed through the local shim |
| OpenCode | official install script | coding TUI connected directly to the OpenAI-compatible endpoint |
| OMP | official install script | coding CLI connected directly to the endpoint |
| WeTTY | global npm package | HTTPS browser terminal on port 1111 |
| LiteLLM | separate Compose image | Anthropic-to-OpenAI request translation |
| SearXNG and Valkey | separate Compose images | internal web search and its state store |
| GNU screen | Ubuntu package | persistent, multiattach terminal sessions |
| Node.js and npm | Ubuntu packages | WeTTY runtime and workspace development |
| Python and `uv` | official `uv` installer | Python runtime and package management |
| Rust and Cargo | `rustup` | Rust development and harness-proxy builds |
| Playwright Chromium | npm installer | browser automation for agent tasks |
| Git, Git LFS, ripgrep, curl, jq | Ubuntu packages | common repository and diagnostic tooling |
| PostgreSQL and SQLite clients | Ubuntu packages | database inspection from the workspace |
| `gosu` | Ubuntu package | root-to-agent privilege drop |

Tool binaries and language package directories are added to `PATH` in the Dockerfile. Rust and Playwright paths are explicit so they continue working when a tool adjusts `HOME`.

## OpenCode configuration

The sandbox mounts global OpenCode commands and skills into every workspace:

```yaml
- ./config/opencode/AGENTS.md:/home/agent/.config/opencode/AGENTS.md:ro
- ./config/opencode/commands:/home/agent/.config/opencode/commands:ro
- ./config/opencode/skills:/home/agent/.config/opencode/skills:ro
- ./config/opencode/agents:/home/agent/.config/opencode/agents:ro
```

Project-specific `AGENTS.md`, commands, and skills can still live inside a project under `workspace/`. Global instructions should remain short and stable; concrete repeatable workflows are easier to maintain as commands or skills.

## Included commands

- `/refactor-audit <target>` inspects refactoring opportunities without editing files.
- `/refactor-apply <approved scope>` applies one focused refactor, verifies it, and updates the worklog.
- `/git-commit` reviews the current work, documents it, and creates a Conventional Commit after approval.

Command definitions live in `config/opencode/commands/`. Edit them on the host and recreate the sandbox if a running tool does not notice the mounted change.

## Included agents and skills

`config/opencode/agents/vision.md` defines the vision-focused OpenCode subagent. The `write-worklog` skill under `config/opencode/skills/` provides a reusable format for recording ad-hoc work in `WORKLOG.md`.

Skills use one directory per skill with a mandatory `SKILL.md`. Keep a skill focused on a reusable capability; keep a command focused on an explicit user-invoked workflow.
