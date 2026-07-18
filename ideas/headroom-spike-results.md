# Headroom spike results (issue #11) — 2026-07-18

Opt-in context-compression sidecar on the brain path, evaluated live against the real chain
(`Claude Code surface -> LiteLLM -> headroom -> reasoning-normalizer -> vLLM on the Sparks`).
Motivation: decode tok/s on the bandwidth-bound Sparks degrades as context grows; goal is
shrinking bloated tool outputs, not token cost (self-hosted).

## What shipped

- `headroom/Dockerfile` — rules-only build (`headroom-ai[proxy]==0.32.0`, no Kompress ML, no ONNX)
- compose service `headroom` behind profile `headroom`, off by default; enable with
  `COMPOSE_PROFILES=headroom LITELLM_BRAIN_URL=http://agentic-headroom:8787/v1 docker compose up -d`
- `tests/test-headroom-interactions-live.sh` — 3 scenarios x N runs: json-needle (fact in big JSON
  survives compression), code-needle (magic constant in big code blob survives), stream-hygiene
  (delta/block pairing + no injected `headroom_*` tool). Reports input_tokens per run.
- `tests/bench-context-toksec.sh` — TTFT + decode tok/s vs context size through the real chain.

## Config that passed all gates (15/15 interactions, 20/20 thinking-path)

`--no-rate-limit --no-cache --no-ccr --stateless`, `HEADROOM_MODE=token`, **without**
`--intercept-tool-results`. Each flag is load-bearing:

- default rate limits (60 rpm / 100k TPM) would throttle agent traffic immediately
- semantic cache could answer from cache instead of the model
- `--no-ccr`: our clients stream and cannot resolve the injected `headroom_retrieve` tool
- `HEADROOM_MODE=cache` (default) froze every turn -> `transforms=none`, 0 tokens saved, pure overhead
- `--intercept-tool-results` (ast-grep code outliner) elided function bodies for ~8% savings and the
  model lost the code it was reading — code-needle went 0/5. Without it, code passes through and 5/5.

## Measured

| payload | before -> after | needle survived | notes |
|---|---|---|---|
| 300-row JSON tool_result | 10004 -> 4023 (-60%) | yes, 5/5 | SmartCrusher keeps outliers; ~15-20ms steady-state overhead (first request ~6.5s warmup) |
| 3.6k-token code blob | untouched | yes, 5/5 | correct: rules-only has no safe code compressor |
| 2k-23k-token text logs | untouched | n/a | prose is Kompress (ML) territory — not installed |
| 94k-token text logs | 93995 -> **99** (-99.9%) | **not tested — content effectively deleted** | ContentRouter misclassified logs as `search`/`code_aware`, kept 0% |

Bench (single-stream): decode tok/s roughly flat 45-56 across 3k-94k input; TTFT linear with
input (3.1s @ 3k, 13.2s @ 23.6k, 50.7s @ 94k). The 64k row through headroom showed TTFT 2.2s —
but only because the payload was destroyed (see above), so it is NOT a win to cite.

## Verdict

Plumbing is sound: streams byte-clean through the sidecar (the fragile thinking path stayed
20/20), no tool injection, negligible steady-state latency. But value for OUR workload is narrow:

1. Real win only on big **JSON** tool results (MCP tools, API responses) — 60% with facts intact.
2. Plain-text tool output (Bash, logs — most of our traffic) is untouched in the rules-only build.
3. **Blocker for default-on**: the giant-text misroute (`router:search:0.00` deleting 94k tokens).
   Needs an upstream issue and/or a size-capped `--protect-tool-results` config before trusting it
   near real sessions. Also single-stream decode tok/s was flat to 94k — the observed Spark
   collapse likely needs bigger contexts or concurrency, which this spike did not reproduce.

Recommendation: keep the profile opt-in and OFF by default (as shipped), report the misroute
upstream, revisit if/when (a) a session is MCP/JSON-heavy or (b) upstream fixes the text misroute
or ships a safe non-ML prose compressor. Follow-up test idea: text-needle scenario at ~90k tokens
to pin the misroute (currently it would fail — which is the point).

## Gotchas for future us

- `docker exec` without `-i` silently drops stdin -> validator files land empty -> tests pass
  vacuously. Both live tests now guard with `[ -s file ]`. (This invalidated all pre-fix "N/N
  clean" results; everything above is post-fix.)
- headroom v0.32.0 ignores `HEADROOM_NO_CCR`/`HEADROOM_STATELESS` as env vars — CLI flags are
  authoritative; verify the startup log after any bump.
- tokenizer cache needs a writable `~/.cache` (tmpfs) or every request re-attempts an HF download.
- LiteLLM reports `input_tokens` only in the final `message_delta` (0 in `message_start`).
