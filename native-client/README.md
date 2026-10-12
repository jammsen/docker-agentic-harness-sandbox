# Native client — Claude Code, OpenCode, OMP, Hermes Agent, no Docker

For someone who already runs Claude Code, OpenCode, OMP, and/or Hermes Agent locally and just
wants to point them at a running [`../server/`](../server/) — no sandbox, no Docker, no browser
terminal.

- **`setup.sh`** (bash + curl + jq) — overview-first, menu-driven, same shape as the sandbox's and
  server's own `model-config.sh`: run it any time, with no prerequisites, and it shows what's
  currently installed and configured before asking you anything. From there:
  - **install requirements** — checks for `curl`/`jq` (needed to run this script at all, via
    `apt-get`/`brew`) and `node`/`npm` (needed by `claude-shim.js` and by searXNG's
    `npx mcp-searxng`). Node is handled separately from `curl`/`jq`: it's never installed as a
    distro package, since those are routinely too old (see below) — instead it installs nvm
    (nodejs.org's own recommended installer) and the current Node LTS + npm through it.
  - **install a tool** — checks each of Claude Code / OpenCode / OMP / Hermes Agent with
    `command -v` and offers to install whichever is missing (same official installers the
    sandbox's Dockerfile uses).
  - **configure a tool** — pick which tool(s) first (installing one on the spot if you don't have
    it yet), *then* a server address incl. `/v1` (defaults to whatever that tool is already
    pointed at, if anything), which it checks is actually reachable and asks the server what it
    really serves (`GET <server>/model/info`, falling back to plain `/v1/models` for a raw vLLM
    box — same two-step probe `../sandbox-client/scripts/model-config.sh` uses, see
    `../server/scripts/render-litellm-config.sh` for why plain `/v1/models` alone isn't enough),
    then lets you pick your own brain (required) and vision (optional) model and writes config for
    the tool(s) you picked. Backs up any existing config before touching it
    (`<file>.bak-<timestamp>`, next to the original — same convention as the sandbox wizard's
    `RESET catalog`).
  - if you picked OpenCode, OMP, and/or Hermes Agent, also asks for a searXNG address (defaults to
    the server's own host on `:8080`, empty to skip) and wires it in as an MCP web-search tool —
    same `mcp-searxng` server the sandbox configures for those tools
    (`../sandbox-client/config/opencode/opencode.json`'s `.mcp` block,
    `../sandbox-client/config/omp/mcp.json`). Claude Code never gets this — it isn't wired up for
    it in the sandbox either.
- **`start-claude-code-shim.sh`** + **`claude-shim.js`** (plain Node, zero dependencies) — only
  needed for Claude Code. Same logic as
  [`../sandbox-client/scripts/claude-shim.js`](../sandbox-client/scripts/claude-shim.js) (image
  hoisting, alias resolution, Anthropic↔OpenAI translation), kept as a separate file on purpose:
  this piece and the sandbox container are meant to stay independently runnable, not share files
  across the split.

OpenCode, OMP, and Hermes Agent don't need `claude-shim` at all — they already speak OpenAI
natively, so `setup.sh` points them straight at the server's own address. Only Claude Code
(Anthropic-only) goes through the shim.

## Prerequisites

- `bash`, `curl`, `jq` — that's it, just to run `setup.sh` and check/install things
- `node` — NOT needed by Claude Code itself (it's a self-contained binary), only by
  `claude-shim.js` in this directory, since that's a plain `.js` file run via `node claude-shim.js`
  (see `start-claude-code-shim.sh`), not a compiled binary. Any reasonably recent Node version — the
  shim is pure stdlib, no npm install needed. Only relevant once you configure Claude Code.
-   **searXNG web search (OpenCode/OMP/Hermes) needs a much newer Node than that: >=22.** It runs
    via `npx mcp-searxng`, whose `undici` dependency hard-requires Node 22 (a `File is not defined`
    crash on anything older, showing as "searxng failed / Disabled" in the tool itself). A plain
    distro `nodejs` package is frequently below this (e.g. Ubuntu 24.04 ships 18.19.1) even though
    it's fine for claude-shim.js — this is why `setup.sh` never installs node via `apt`/`brew`.
    `setup.sh` checks the version everywhere it matters (overview, install requirements, setting
    the searXNG address) and, when it's insufficient, offers to install nvm + the current Node LTS
    + npm through it right there.
- Claude Code / OpenCode / OMP / Hermes Agent themselves are NOT prerequisites — `setup.sh` checks
  for each and offers to install whichever you want

## Setup

```bash
./setup.sh
```

You'll see an overview of what's installed and configured (nothing, the first time). From there,
pick **i) install a tool** and/or **c) configure a tool** — run it again any time just to check
current status, no prompts forced on you. Configuring backs up your old config each time rather
than overwriting blind, so re-running to switch servers or add another tool is safe.

**Claude Code** additionally needs the shim kept running:

```bash
./start-claude-code-shim.sh   # keep running — a terminal tab, tmux, systemd --user, launchd, whatever you use
```

`setup.sh` merges these into the `env` block of `~/.claude/settings.json` (everything else in that
file is left alone):

```
ANTHROPIC_BASE_URL=http://127.0.0.1:3999
ANTHROPIC_DEFAULT_OPUS_MODEL=opus
ANTHROPIC_DEFAULT_SONNET_MODEL=sonnet
ANTHROPIC_DEFAULT_HAIKU_MODEL=haiku
ANTHROPIC_DEFAULT_FABLE_MODEL=fable
```

These are stable slot names `claude-shim` resolves against your catalog, not literal model ids —
same convention the sandbox client uses (`../sandbox-client/config/claude/settings.json`), so `/model`
inside Claude Code still works the same way.

`setup.sh` also merges onboarding/trust state into `~/.claude.json` (`hasCompletedOnboarding`,
`hasTrustDialogAccepted`, `theme`, and approving the `dummy` API key `claude-shim` expects) — same
fields the sandbox pre-seeds (`../sandbox-client/config/claude/claude.json`) — so a fresh Claude
Code install skips straight to a working session instead of stopping at its own first-run wizard.

**OpenCode**, **OMP**, and **Hermes Agent** need nothing kept running — `setup.sh` writes their
provider config pointing directly at the server, and you're done:
(`~/.config/opencode/opencode.json`'s `provider`/`model`, `~/.omp/agent/models.yml` +
`config.yml`, `~/.hermes/config.yaml`). For OpenCode each model entry also gets a
`limit: {context, output}` from the server-reported windows — without it OpenCode defaults both
to 0 (its models.dev catalog never lists a self-hosted model), so the context-usage display
sticks at 0% and auto-compact has no window to work with. When the server doesn't report an
output window, `limit.output` defaults to 16384 (same maxTokens the OMP path assumes), since
OpenCode's `limit` schema requires both fields.

**Hermes Agent**'s config (`~/.hermes/config.yaml`) gets three things:

- the `model:` block — `provider: custom` + `base_url` + `default` model id, plus
  `context_length` (the server-reported context window, when it reported one) — the same fields
  Hermes' own `hermes model` → "Custom endpoint" wizard saves (config.yaml is Hermes' single
  source of truth; no `.env` model entries are used). `context_length` matters: it's Hermes'
  step-0 context override, and without it Hermes guesses from hardcoded per-family defaults
  (e.g. any "glm*" model name → the glm catalog value), which is wrong for most self-hosted
  serving configs — compaction thresholds inherit the wrong window as a result. Must be a plain
  integer; a `"256K"`-style string is warned about and ignored by Hermes. If a config.yaml
  already exists, it's backed up and updated through Hermes' own `hermes config set` CLI, so
  everything else in it (profiles, gateway, skills, memory settings, ...) is preserved; only the
  `model.*` scalars are rewritten.
- `providers.custom.models.<brain>.supports_vision` — **this one matters**: it's the vision flag
  from the "Can '$brain' see images (vision)?" question, written explicitly as true *or* false.
  Without it, Hermes tries to discover vision capability on its own — via the models.dev catalog
  (a self-hosted vLLM/LiteLLM model will never be listed there) and an Ollama-specific endpoint
  probe (not applicable either) — and with the capability unknown it silently routes every
  attached image through its `vision_analyze` auxiliary model (a lossy text description) instead
  of sending it natively as image parts. Same trap OpenCode's `attachment` flag fixes, same fix.
- `mcp_servers.searxng` — the searXNG web-search MCP server (`npx mcp-searxng`), same env vars the
  OpenCode/OMP configs carry. Written only when you gave a searXNG address.

## Testing

`tests/test-setup-helpers.sh` — unit + write-path tests for the Hermes Agent and OpenCode
model-catalog handling in `setup.sh` (YAML status helpers, the vision/context-limit jq program,
both Hermes write paths against a mock of `hermes config`). Everything it exercises is extracted
from `setup.sh` at runtime, so it can't drift from the code it covers. Needs `bash`, `jq`,
`python3` (with PyYAML for the YAML-shape assertions — skipped with a note without it). Run it
with `bash tests/test-setup-helpers.sh`; no hermes install required.

## Why this exists, not just the Docker sandbox

The sandbox (`../sandbox-client/`) is a full hardened environment — browser terminal, multiple tools,
process isolation. That's a real, deliberate choice for some setups, but it's not reasonable to
require someone who already runs these tools locally to also run a container just to reach a model
server. This package is the same underlying logic (catalog, alias resolution, the Claude-only
translation shim), packaged for that person instead.

## Multi-server mixing

If you want to mix this server's model with another one (someone else's, or a second server of
your own), edit `~/.config/agentic-harness-native/models.json` by hand — add another entry under
`servers` with `"anthropic": true` if that URL is itself a full server/litellm gateway (see the
commented-out example server in `../sandbox-client/config/models/models.example.yml` for the exact shape
— same fields, that file is just YAML instead of this catalog's plain JSON). This only affects
Claude Code (via `claude-shim`) — `setup.sh` only handles the single-server case for it; hand-editing
the same catalog format works identically here and in the sandbox client. OpenCode, OMP, and
Hermes Agent each have their own native multi-provider config if you want to add a second server
for them (for Hermes: the `custom_providers` list or named entries under `providers.` in
`~/.hermes/config.yaml`) — edit their config files directly, same as you would without this
project at all.
