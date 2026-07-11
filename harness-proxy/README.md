# harness-proxy

A tiny Rust proxy that lets **Claude Code** talk to a local **vLLM** (or any
OpenAI-compatible) inference server. It translates the Anthropic Messages API
(`/v1/messages`) into OpenAI Chat Completions (`/v1/chat/completions`) and back.

It is the in-house replacement for the **LiteLLM sidecar + `claude-shim.js`** pair
described in the [root README](../README.md) (see *Included Software*). Tracks
GitHub issue **#10**. The full design, rationale and roadmap live in
[`PLAN.md`](./PLAN.md) — this file is the short "what / why / how" for someone
landing in this directory.

---

## Why this exists

The sandbox runs agentic coding tools against *your own* vLLM model — no cloud
API keys (see the root README). Claude Code only speaks the **Anthropic** wire
format; vLLM only speaks the **OpenAI** one. Something has to translate between
them. Today that job is split across two moving parts:

- **LiteLLM** (a Python service) does the Anthropic↔OpenAI translation, and
- **`claude-shim.js`** (a Node sidecar) patches around a LiteLLM bug that drops
  images out of `tool_result` blocks.

That's two languages, two processes, a large dependency surface, and a supply-chain
footprint (LiteLLM had compromised PyPI releases — see the version note in
`compose.yml`). `harness-proxy` collapses both into **one ~1 MB static binary**
with no runtime dependencies, doing the translation — including the image fix —
directly.

## How it works

```
Claude Code ──Anthropic /v1/messages──▶ harness-proxy ──OpenAI /v1/chat/completions──▶ vLLM
            ◀──Anthropic response──────              ◀──OpenAI response───────────────
```

- **Request:** force the upstream model (alias map — any incoming model →
  `VLLM_MODEL`), turn the Anthropic `system` + message content blocks into OpenAI
  messages, strip Anthropic-only params.
- **Response:** map `choices[].message` → Anthropic `content`, `finish_reason` →
  `stop_reason`, and `usage` token counts back to Anthropic's names. A native tool-call payload
  forces `stop_reason: tool_use`, including vLLM 0.23 responses that incorrectly finish with `stop`.

Translation lives in `src/translate.rs`; the wire types are in `src/anthropic.rs`
and `src/openai.rs`; `src/main.rs` is the axum server. See [`PLAN.md` §5](./PLAN.md)
for the field-by-field mapping.

Operational logs are metadata-only: request ID, method, path, status, latency, model and upstream
status. Prompts, tool arguments, images, headers and upstream bodies are never logged. The startup
endpoint is reduced to scheme/host/port (credentials, path and query are removed); tokenization
fallbacks and mid-stream failures emit correlated warnings/errors with safe reason categories.
Docker `SIGTERM` and foreground `SIGINT` trigger Axum graceful shutdown: the proxy stops accepting
new connections, drains active connections, and logs shutdown receipt and completion. Drain time is
bounded by `HARNESS_PROXY_SHUTDOWN_TIMEOUT_SECS` (default `8`, below Docker's default 10-second stop
deadline), after which remaining long-lived streams are closed cleanly by process exit. The image
declares `STOPSIGNAL SIGTERM`, so this also works when the binary runs directly as container PID 1.

## Status

Built incrementally (roadmap in [`PLAN.md` §6](./PLAN.md)):

| | Capability | State |
|---|---|---|
| 1 | Scaffold, Dockerfile, `/health` | ✅ done |
| 2 | Non-streaming `/v1/messages` translation (text) | ✅ done |
| 3 | Streaming SSE | ✅ done |
| 4 | Image hoist, param strip, `count_tokens` | ✅ done |
| 5 | Tool-call translation | ✅ done |
| 6 | Production logging & error handling | ✅ done |
| 7 | Cut over: remove LiteLLM + `claude-shim.js` | ⏳ planned (gated — do last) |

Until the cutover the proxy can run **alongside** LiteLLM on a separate port, so nothing
in the existing sandbox breaks while it is being proven. The root Compose definition is currently
commented out; enable it explicitly for a standalone verification run.

## Configuration

All config is via environment variables — no config file (see `compose.yml`,
service `harness-proxy`):

| Env | Required | Meaning |
|---|---|---|
| `VLLM_URL` | **yes** | Base URL of the OpenAI-compatible server, e.g. `http://10.0.0.13:8000` |
| `VLLM_MODEL` | **yes** | Upstream model id every request is forced to, e.g. `qwen3.6-35b` |
| `HARNESS_PROXY_BIND` | no (default `0.0.0.0:4000`) | Listen address |
| `HARNESS_PROXY_TIMEOUT_SECS` | no (default `600`) | Non-streaming upstream request timeout |
| `HARNESS_PROXY_BODY_LIMIT_BYTES` | no (default `33554432`) | Maximum accepted Anthropic request body size |
| `HARNESS_PROXY_SHUTDOWN_TIMEOUT_SECS` | no (default `8`) | Graceful connection-drain limit before exit |

`VLLM_URL` / `VLLM_MODEL` are deployment-specific and **not** baked into the
binary — the process refuses to start if either is missing.

## Build & run

The image is a multi-stage build: an Ubuntu builder produces a fully static
musl binary, copied into a `FROM scratch` final stage (no libc, runs as a
non-root numeric UID). See `Dockerfile` and [`PLAN.md` §3](./PLAN.md).

```bash
# from the repo root
./harness-proxy/build-image.sh harness-proxy:local
docker run --rm -p 127.0.0.1:4000:4000 \
  -e HARNESS_PROXY_BIND=0.0.0.0:4000 \
  -e VLLM_URL=http://YOUR_VLLM_IP:8000/v1 \
  -e VLLM_MODEL=qwen3.6-35b \
  harness-proxy:local

# in another terminal
curl -s http://127.0.0.1:4000/health   # -> ok
docker inspect harness-proxy:local \
  --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'
```

`Cargo.toml` is the single version source. The build wrapper reads its package version and passes it
to the OCI image label; the Dockerfile verifies the value still matches before compiling. The binary
uses Rust's compile-time `CARGO_PKG_VERSION`, so the same version appears in startup logs. Do not call
`docker build` directly—the required version argument is intentionally supplied by the wrapper.

The root Compose service remains commented out until Step 7. Alternatively, uncomment that complete
block for the separate-service topology instead of using `docker run`.

## Develop & test

A local Rust toolchain (edition 2024 / Rust ≥ 1.85) is enough for the unit tests:

```bash
cd harness-proxy
cargo test            # translation unit tests
cargo clippy --all-targets -- -D warnings
```

Current verification: **17/17 tests**, formatting, strict Clippy, static Docker build, and live
vLLM checks for normal and streaming messages, thinking, tool loops, token counting, nested
`tool_result` images, sanitized logs, 400 validation, 502 upstream failure, and 504 timeout handling.

vLLM lives on the LAN and usually isn't reachable from a dev laptop. To exercise
the live HTTP path without it, point `VLLM_URL` at a small local OpenAI mock that
returns a canned `chat.completion`, then run the container against it. The real
end-to-end test is in-container against vLLM — see [`PLAN.md` §7](./PLAN.md).

The deterministic live vision fixture is
[`tests/fixtures/vision-test-7319.png`](./tests/fixtures/vision-test-7319.png): red circle, blue square,
yellow triangle, and the text `VISION TEST 7319`. Send it as base64 inside an Anthropic
`tool_result` image block to verify that image hoisting reaches the vision model.
