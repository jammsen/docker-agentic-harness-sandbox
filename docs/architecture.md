---
sidebar_position: 5
title: Architecture
---

# Architecture

```text
Browser ──HTTPS──> WeTTY :1111 ──> agent-session.sh ──> screen ──> agent tool
                         │
Browser ──HTTPS──> upload server :1112 ──> workspace/uploads

OpenCode / OMP ───────────────────────────────────────────────> vLLM /v1
Claude Code ──> claude-shim :4001 ──> LiteLLM :4000 ─────────> vLLM /v1

OpenCode / OMP ──> SearXNG :8080 ──> Valkey
```

`scripts/entrypoint.sh` runs once as the container supervisor. It prepares ownership and configuration and launches background services. WeTTY starts `scripts/agent-session.sh` for each browser connection; that script drops privileges with `gosu`, manages screen sessions, and starts the selected tool.

The `harness-proxy` service is a work in progress. Its goal is to replace the Claude shim and LiteLLM translation chain, but the active Claude Code configuration still points to the shim and LiteLLM.
