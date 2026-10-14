# opencode plugin: tok/s meter

Live tokens-per-second readout for the opencode TUI prompt footer, plus a
frozen `tok/s <avg> avg · ↑<max> ↓<min>` summary after each response.

- V2-only (opencode 2.x TUI plugin API: `Plugin.define` + `context.ui.slot`
  under `prompt.footer.status`). Ported from `@mesaleh/opencode-tps` 0.3.0
  (V1), then fixed on 2026-10-14 — see "Token accounting" below.
- `index.ts` is the server-side stub (required entrypoint, no hooks).
  `tui.tsx` (export `./tui`) is the TUI part: live 5 s rolling-window rate
  from `session.text.delta` / `session.reasoning.delta` (bytes ÷ 5.5),
  frozen per-turn summary.

## Token accounting (why not `session.usage.updated`)

`session.usage.updated.tokens` is **cumulative for the whole session** (its
output equals the sum of all assistant messages' `tokens.output`), while
`session.step.ended` carries the provider-reported tokens **per step** (one
step = one assistant message). The first version of this plugin treated the
session-cumulative number as the current message's output, which inflated
the frozen average by roughly the number of messages in the session and let
stale values from the previous turn freeze the next message early.

The fixed version therefore:

- accumulates `tokens.output + tokens.reasoning` per turn from
  `session.step.ended` (a turn with tool calls spans several steps),
- freezes on the final step (`finish !== "tool-calls"`) or on
  `session.execution.succeeded` / `.failed` / `.interrupted`,
- counts reasoning deltas in the streaming estimate,
- clears the live window on `session.step.started` (not only on tool calls).

## Sandbox wiring

The TUI part cannot resolve its `solid-js` / `@opentui/*` imports without an
installed `node_modules` (verified: the TUI reports "Plugin failed:
opencode-toks" otherwise), and `config/opencode/` files are mounted
read-only — so the plugin is **baked into the image** by the Dockerfile:

```
COPY config/opencode/plugin/toks → /home/agent/.opencode-plugins/toks
npm ci                           → installs deps from package-lock.json
```

`/home/agent/.opencode-plugins/` deliberately sits outside
`~/.config/opencode/`: a directory there is picked up by opencode's global
plugin-dir scan, so with the explicit entry in the `opencode.json` template
the plugin would load twice. The template contains:

```jsonc
"plugins": ["/home/agent/.opencode-plugins/toks"]
```

`scripts/render-models.sh` passes unknown template keys through `jq`
untouched, so the entry survives every re-render. Rebuild the image to
update the plugin.
