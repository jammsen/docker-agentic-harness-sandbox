/** @jsxImportSource @opentui/solid */
import { createMemo, createSignal } from "solid-js"
import { Plugin } from "@opencode/plugin/tui"

// tok/s display for the prompt footer — V2 port of @mesaleh/opencode-tps 0.3.0.
//
// Estimates output tokens from streamed text/reasoning deltas (bytes / 5.5)
// over a sliding 5 s window for the live rate, and freezes avg/max/min when
// the assistant turn finishes.
//
// Real output tokens come from `session.step.ended`, which carries the
// provider-reported token count PER STEP (one step = one assistant message).
// `session.usage.updated` is deliberately NOT used for this: its `tokens` are
// cumulative for the whole session (verified against opencode.db, where
// session.tokens_output equals the sum of all assistant messages' outputs),
// so treating it per-message inflated the average by the number of messages
// in the session. Step tokens are accumulated per turn (a turn with tool
// calls spans several steps) and the summary freezes on the final step
// (finish reason != "tool-calls") or when the turn's execution ends.

interface StreamSample {
  tokens: number
  timestamp: number
}

interface MessageStats {
  firstDeltaTs: number
  totalEstTokens: number
  endedTs?: number
  maxLiveTps: number // -Infinity until first warm sample
  minLiveTps: number // Infinity until first warm sample
  frozen?: { avg: number; max: number; min: number }
}

const LIVE_STALE_MS = 1500
const SAMPLE_WINDOW_MS = 5000
const SINGLE_SAMPLE_MIN_MS = 250
const SINGLE_SAMPLE_MAX_MS = 1000
const WARMUP_MS = 3000
const BYTES_PER_TOKEN_ESTIMATE = 5.5
const FREEZE_FALLBACK_MS = 2500

function estimateTokens(text: string): number {
  const byteLen = new TextEncoder().encode(text).length
  return Math.max(1, Math.ceil(byteLen / BYTES_PER_TOKEN_ESTIMATE))
}

function formatTps(value: number): string {
  if (value < 0) return "-"
  if (value < 10) return value.toFixed(2)
  if (value < 100) return value.toFixed(1)
  return Math.round(value).toString()
}

function singleSampleDuration(samples: StreamSample[]): number {
  const elapsed = Date.now() - samples[0].timestamp
  return Math.max(SINGLE_SAMPLE_MIN_MS, Math.min(elapsed, SINGLE_SAMPLE_MAX_MS))
}

function activeDurationMs(samples: StreamSample[]): number {
  if (samples.length < 2) {
    return singleSampleDuration(samples)
  }
  // The host batches deltas (~100 ms flushes), so several samples can share
  // a timestamp. Use the wall-clock span of the window plus the (capped)
  // quiet tail after the last sample — inter-arrival sums would undercount
  // whenever a flush delivers multiple deltas in the same millisecond.
  const span = samples[samples.length - 1].timestamp - samples[0].timestamp
  const tail = Math.min(Date.now() - samples[samples.length - 1].timestamp, LIVE_STALE_MS)
  return Math.max(span + tail, SINGLE_SAMPLE_MIN_MS)
}

export interface FreezableStats {
  durationMs: number
  totalEstTokens: number
  maxLiveTps: number
  minLiveTps: number
}

/**
 * Pure summary math: avg from the turn's real provider tokens when known
 * (per-turn sum of session.step.ended outputs, NOT the session-cumulative
 * session.usage.updated tokens), max/min rescaled onto the same scale.
 */
export function computeFrozen(
  stats: FreezableStats,
  realTokens: number | undefined,
): { avg: number; max: number; min: number } {
  const tokensForAvg = realTokens !== undefined && realTokens > 0 ? realTokens : stats.totalEstTokens
  const avg = (tokensForAvg / stats.durationMs) * 1000

  let max = stats.maxLiveTps
  let min = stats.minLiveTps
  if (!isFinite(max) || !isFinite(min)) {
    max = avg
    min = avg
  } else if (realTokens !== undefined && realTokens > 0 && stats.totalEstTokens > 0) {
    const scale = realTokens / stats.totalEstTokens
    max = max * scale
    min = min * scale
  }
  return { avg, max, min }
}

export default Plugin.define({
  id: "opencode-toks",
  setup(context) {
    const streamSamples = new Map<string, StreamSample[]>()
    const messageStats = new Map<string, MessageStats>()
    // Provider-reported output tokens accumulated for the CURRENT turn.
    // One turn can span several steps (tool calls); `session.step.ended`
    // reports per-step tokens, so they are summed here.
    const turnRealTokens = new Map<string, number>()

    const [version, setVersion] = createSignal(0)
    const [tick, setTick] = createSignal(0)

    function clearLiveSamples(sessionID: string) {
      if (streamSamples.has(sessionID)) {
        streamSamples.delete(sessionID)
        setVersion((v) => v + 1)
      }
    }

    function calcLiveTps(sessionID: string): number {
      if (context.data.session.status(sessionID) === "idle") return -1

      const samples = streamSamples.get(sessionID) ?? []
      const now = Date.now()
      const cutoff = now - SAMPLE_WINDOW_MS
      const active = samples.filter((s) => s.timestamp >= cutoff)

      if (active.length === 0) return -1

      const last = active[active.length - 1]
      if (now - last.timestamp > LIVE_STALE_MS) return -1

      const totalTokens = active.reduce((sum, s) => sum + s.tokens, 0)
      const durationMs = activeDurationMs(active)
      if (durationMs <= 0) return -1

      return (totalTokens / durationMs) * 1000
    }

    function freeze(sessionID: string) {
      const stats = messageStats.get(sessionID)
      if (!stats) {
        // Terminal turn with no streamed deltas (a step can report tokens
        // without ever streaming visible text): nothing to freeze, but the
        // accumulator must not leak into the next turn — a coalesced turn can
        // start without a fresh session.execution.started.
        turnRealTokens.delete(sessionID)
        return
      }
      if (stats.frozen) return

      const endedTs = stats.endedTs ?? Date.now()
      const durationMs = Math.max(1, endedTs - stats.firstDeltaTs)

      stats.frozen = computeFrozen(
        {
          durationMs,
          totalEstTokens: stats.totalEstTokens,
          maxLiveTps: stats.maxLiveTps,
          minLiveTps: stats.minLiveTps,
        },
        turnRealTokens.get(sessionID),
      )
      turnRealTokens.delete(sessionID)
      streamSamples.delete(sessionID)
      setVersion((v) => v + 1)
    }

    function handleStreamDelta(sessionID: string, deltaText: string) {
      if (context.data.session.status(sessionID) === "idle") return
      if (!deltaText) return

      const tokens = estimateTokens(deltaText)
      const now = Date.now()

      let samples = streamSamples.get(sessionID)
      if (!samples) {
        samples = []
        streamSamples.set(sessionID, samples)
      }
      samples.push({ tokens, timestamp: now })

      let stats = messageStats.get(sessionID)
      if (!stats || stats.frozen) {
        // A frozen entry from the previous turn — replace it (new response
        // starting). turnRealTokens is NOT reset here: steps that ran before
        // the first visible delta (e.g. a leading tool call) already
        // contributed to this turn's total.
        stats = {
          firstDeltaTs: now,
          totalEstTokens: 0,
          maxLiveTps: -Infinity,
          minLiveTps: Infinity,
        }
        messageStats.set(sessionID, stats)
      }
      stats.totalEstTokens += tokens

      setVersion((v) => v + 1)
    }

    const offDelta = context.data.on("session.text.delta", (event: any) => {
      const d = event?.data
      if (!d?.sessionID) return
      if (typeof d.delta === "string") handleStreamDelta(d.sessionID, d.delta)
    })

    // Reasoning streams are model output too — count them, so the live rate
    // and the real/estimate rescale stay consistent for reasoning models.
    const offReasoning = context.data.on("session.reasoning.delta", (event: any) => {
      const d = event?.data
      if (!d?.sessionID) return
      if (typeof d.delta === "string") handleStreamDelta(d.sessionID, d.delta)
    })

    const offStepStarted = context.data.on("session.step.started", (event: any) => {
      const d = event?.data
      // A new step starts a fresh stream — the live window must not bridge
      // the gap between steps (covers transitions without tool calls).
      if (d?.sessionID) clearLiveSamples(d.sessionID)
    })

    const offStepEnded = context.data.on("session.step.ended", (event: any) => {
      const d = event?.data
      const sessionID = d?.sessionID
      if (!sessionID) return

      const output = d?.tokens?.output
      const reasoning = d?.tokens?.reasoning
      const stepTokens =
        (typeof output === "number" && isFinite(output) ? output : 0) +
        (typeof reasoning === "number" && isFinite(reasoning) ? reasoning : 0)
      if (stepTokens > 0) {
        // Skip when the turn's summary is already frozen (late-arriving step
        // end) — the accumulator must not carry tokens into the next turn,
        // which may start without a fresh session.execution.started.
        const stats = messageStats.get(sessionID)
        if (!stats || !stats.frozen) {
          turnRealTokens.set(sessionID, (turnRealTokens.get(sessionID) ?? 0) + stepTokens)
        }
      }

      // The final step of a turn ends with a real finish reason; a
      // "tool-calls" step is a mid-turn continuation, so keep accumulating.
      if (d?.finish && d.finish !== "tool-calls") freeze(sessionID)
    })

    const offTextEnded = context.data.on("session.text.ended", (event: any) => {
      const d = event?.data
      const sessionID = d?.sessionID
      if (!sessionID) return
      const stats = messageStats.get(sessionID)
      if (stats && !stats.frozen) {
        stats.endedTs = Date.now()
        // Safety net: if neither the final step.ended nor a turn-terminal
        // execution event freezes the summary (e.g. a provider that reports
        // no usage), freeze shortly after the stream goes quiet — but only
        // while the session is really idle, never mid-turn.
        setTimeout(() => {
          if (context.data.session.status(sessionID) === "idle") freeze(sessionID)
        }, FREEZE_FALLBACK_MS)
      }
    })

    // Turn boundaries: reset the per-turn token accumulator at the start,
    // freeze the summary at any terminal outcome (success, failure, abort).
    const offExecStarted = context.data.on("session.execution.started", (event: any) => {
      const sessionID = event?.data?.sessionID
      if (sessionID) turnRealTokens.delete(sessionID)
    })
    const offExecDone = context.data.on("session.execution.succeeded", (event: any) => {
      if (event?.data?.sessionID) freeze(event.data.sessionID)
    })
    const offExecFailed = context.data.on("session.execution.failed", (event: any) => {
      if (event?.data?.sessionID) freeze(event.data.sessionID)
    })
    const offExecInterrupted = context.data.on("session.execution.interrupted", (event: any) => {
      if (event?.data?.sessionID) freeze(event.data.sessionID)
    })

    // A tool call pauses the text stream — the window must not bridge it.
    const offTool = context.data.on("session.tool.called", (event: any) => {
      const d = event?.data
      if (d?.sessionID) clearLiveSamples(d.sessionID)
    })

    const interval = setInterval(() => {
      const now = Date.now()
      const cutoff = now - SAMPLE_WINDOW_MS
      for (const [sessionID, samples] of streamSamples) {
        const pruned = samples.filter((s) => s.timestamp >= cutoff)
        if (pruned.length !== samples.length) {
          streamSamples.set(sessionID, pruned)
        }
      }
      for (const [sessionID, stats] of messageStats) {
        if (stats.frozen) continue
        if (now - stats.firstDeltaTs < WARMUP_MS) continue
        const liveTps = calcLiveTps(sessionID)
        if (liveTps <= 0) continue
        if (liveTps > stats.maxLiveTps) stats.maxLiveTps = liveTps
        if (liveTps < stats.minLiveTps) stats.minLiveTps = liveTps
      }
      setTick((t) => t + 1)
    }, 1000)

    const unregister = context.ui.slot({
      append: "prompt.footer.status",
      render: (props: any) => {
        const sessionID = props?.sessionID

        const display = createMemo(() => {
          version()
          tick()
          const stats = messageStats.get(sessionID)
          if (stats?.frozen) {
            const { avg, max, min } = stats.frozen
            return `tok/s ${formatTps(avg)} avg · ↑${formatTps(max)} ↓${formatTps(min)}`
          }
          const live = calcLiveTps(sessionID)
          if (live > 0) return `tok/s ${formatTps(live)}`
          return "tok/s -"
        })

        const theme = context.theme as any
        const muted = theme?.text?.muted ?? theme?.text?.base

        return <text fg={muted}>{display()}</text>
      },
    })

    return () => {
      unregister()
      offDelta()
      offReasoning()
      offStepStarted()
      offStepEnded()
      offTextEnded()
      offExecStarted()
      offExecDone()
      offExecFailed()
      offExecInterrupted()
      offTool()
      clearInterval(interval)
      messageStats.clear()
      streamSamples.clear()
      turnRealTokens.clear()
    }
  },
})
