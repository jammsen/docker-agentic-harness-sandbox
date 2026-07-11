---
sidebar_position: 1
slug: /
title: Introduction
---

# Agentic Harness Sandbox

Agentic Harness Sandbox runs Claude Code, OpenCode, and OMP in one Docker Compose stack. A browser connects to a WeTTY terminal over HTTPS, while the tools send inference requests to a vLLM server or another OpenAI-compatible API that you control.

The stack is aimed at trusted home-lab and development networks. It provides persistent terminal sessions, a host-mounted project workspace, image uploads, internal web search, and a translation path that lets Claude Code use an OpenAI-compatible model.

## What runs in the stack

- `sandbox`: the browser terminal and all three coding tools
- `litellm`: translates Anthropic-compatible requests to vLLM chat completions
- `searxng` and `valkey`: internal web search for supported tools
- `harness-proxy`: an experimental Rust replacement for the LiteLLM/shim path; it is built but is not the active request path

Start with [Getting started](./getting-started.md), then use [Configuration](./configuration.md) to select your endpoint and model.
