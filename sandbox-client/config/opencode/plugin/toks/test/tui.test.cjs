const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const { resolve } = require("node:path")
const { test } = require("node:test")
const { runInNewContext } = require("node:vm")
const ts = require("typescript")

// Run the real plugin handlers with a deterministic clock and a minimal host.
// No terminal/native rendering dependencies or model server are needed.
const sourcePath = process.env.TOKS_SOURCE || resolve(__dirname, "../tui.tsx")
const compiled = ts.transpileModule(readFileSync(sourcePath, "utf8"), {
  fileName: sourcePath,
  compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
}).outputText

function harness(t) {
  let now = 1000
  let status = "busy"
  let render
  const listeners = new Map()
  const timers = new Set()
  const intervals = new Set()
  const exports = {}
  runInNewContext(compiled, {
    exports,
    require(name) {
      if (name === "solid-js") return {
        createSignal(initial) {
          let value = initial
          return [() => value, (next) => { value = typeof next === "function" ? next(value) : next }]
        },
        createMemo: (fn) => fn,
      }
      if (name === "@opencode/plugin/tui") return { Plugin: { define: (plugin) => plugin } }
      if (name === "@opentui/solid/jsx-runtime") return { jsx: (_type, props) => props }
      throw new Error(`Unexpected import: ${name}`)
    },
    TextEncoder,
    Date: class extends Date { static now() { return now } },
    setTimeout(fn, delay) { const timer = { fn, at: now + delay }; timers.add(timer); return timer },
    clearTimeout(timer) { timers.delete(timer) },
    setInterval(fn) { intervals.add(fn); return fn },
    clearInterval(fn) { intervals.delete(fn) },
  })
  const dispose = exports.default.setup({
    data: {
      session: { status: () => status },
      on(name, fn) { listeners.set(name, fn); return () => listeners.delete(name) },
    },
    ui: { slot(options) { render = options.render; return () => { render = undefined } } },
    theme: {},
  })
  t.after(dispose)
  const emit = (name, data = {}) => listeners.get(`session.${name}`)?.({ data: { sessionID: "s", ...data } })
  const meter = {
    emit,
    advance(ms) { now += ms },
    tick() { for (const fn of intervals) fn() },
    runTimers() { for (const timer of timers) if (timer.at <= now) { timers.delete(timer); timer.fn() } },
    idle() { status = "idle" },
    start(id) { emit("step.started", { assistantMessageID: id }) },
    delta(id, text = "a".repeat(55), kind = "text") {
      emit(`${kind}.delta`, { assistantMessageID: id, delta: text })
    },
    textEnd(id) { emit("text.ended", { assistantMessageID: id }) },
    end(id, output, finish = "stop", reasoning = 0) {
      emit("step.ended", { assistantMessageID: id, tokens: { output, reasoning }, finish })
    },
    display() { return render({ sessionID: "s" }).children },
    average() {
      const text = meter.display()
      assert.match(text, /^tok\/s [\d.]+ avg/)
      return Number(text.split(" ")[1])
    },
    turn(id, tokens = 100) {
      meter.start(id)
      meter.delta(id)
      meter.advance(1000)
      meter.textEnd(id)
      meter.end(id, tokens)
    },
    computeFrozen: exports.computeFrozen,
  }
  return meter
}

test("short deltas have the same live rate and fallback average as one combined delta", (t) => {
  const fragmented = harness(t)
  const combined = harness(t)
  fragmented.start("a")
  combined.start("b")
  for (let i = 0; i < 10; i++) fragmented.delta("a", "a")
  combined.delta("b", "a".repeat(10))
  fragmented.advance(1000)
  combined.advance(1000)
  assert.equal(fragmented.display(), "tok/s 1.82")
  assert.equal(fragmented.display(), combined.display())
  fragmented.textEnd("a")
  combined.textEnd("b")
  fragmented.end("a", 0)
  combined.end("b", 0)
  assert.equal(fragmented.average(), 1.82)
  assert.equal(fragmented.display(), combined.display())
})

test("UTF-8 reasoning and text fragments both contribute fractional estimates", (t) => {
  const m = harness(t)
  m.start("a")
  m.delta("a", "é", "reasoning") // 2 bytes
  m.delta("a", "abc") // 3 bytes
  m.delta("a", "")
  m.advance(1000)
  m.textEnd("a")
  m.end("a", 0)
  assert.equal(m.average(), 0.91)
})

test("a coalesced new turn counts its leading tool-only step after a frozen summary", (t) => {
  const m = harness(t)
  m.turn("old", 900)
  m.start("tool") // No execution.started or visible delta for this new turn.
  m.emit("tool.called", { assistantMessageID: "tool" })
  m.end("tool", 20, "tool-calls", 10)
  m.start("answer")
  m.delta("answer")
  m.advance(1000)
  m.textEnd("answer")
  m.end("answer", 70)
  assert.equal(m.average(), 100)
})

test("late prior-step events cannot freeze or contaminate the current turn", (t) => {
  const m = harness(t)
  m.turn("old", 900)
  m.start("new")
  m.delta("new")
  m.advance(500)
  m.end("old", 9000)
  m.delta("old", "x".repeat(5500))
  m.textEnd("old")
  assert.doesNotMatch(m.display(), /avg/)
  m.advance(500)
  m.textEnd("new")
  m.end("new", 100)
  assert.equal(m.average(), 100)
})

test("length continuations keep all provider tokens and the full duration", (t) => {
  const m = harness(t)
  m.start("first")
  m.delta("first")
  m.advance(1000)
  m.textEnd("first")
  m.end("first", 80, "length", 20)
  assert.doesNotMatch(m.display(), /avg/)
  m.start("continued")
  m.delta("continued")
  m.advance(1000)
  m.textEnd("continued")
  m.end("continued", 100)
  assert.equal(m.average(), 100)
})

test("reasoning-only continuation does not reuse an earlier text end timestamp", (t) => {
  const m = harness(t)
  m.start("first")
  m.delta("first")
  m.advance(1000)
  m.textEnd("first")
  m.end("first", 100, "length")
  m.start("continued")
  m.delta("continued", "reasoning", "reasoning")
  m.advance(1000)
  m.end("continued", 0, "stop", 100)
  assert.equal(m.average(), 100)
})

test("a stop with a local tool still preserves totals for continuation", (t) => {
  const m = harness(t)
  m.start("tool")
  m.delta("tool")
  m.advance(1000)
  m.textEnd("tool")
  m.emit("tool.called", { assistantMessageID: "tool", executed: false })
  m.end("tool", 100, "stop")
  assert.doesNotMatch(m.display(), /avg/)
  m.start("answer")
  m.delta("answer")
  m.advance(1000)
  m.textEnd("answer")
  m.end("answer", 100)
  assert.equal(m.average(), 100)
})

test("duplicate step.ended and old continuation events are counted once", (t) => {
  const m = harness(t)
  m.start("tool")
  m.end("tool", 30, "tool-calls")
  m.end("tool", 30, "tool-calls")
  m.start("answer")
  m.delta("answer")
  m.end("tool", 9000)
  m.advance(1000)
  m.textEnd("answer")
  m.end("answer", 70)
  assert.equal(m.average(), 100)
})

test("a terminal turn without visible deltas cannot leak tokens to the next turn", (t) => {
  const m = harness(t)
  m.turn("old")
  m.start("invisible")
  m.end("invisible", 9000)
  m.end("invisible", 9000)
  m.turn("next", 100)
  assert.equal(m.average(), 100)
})

for (const terminal of ["succeeded", "failed", "interrupted"]) {
  test(`execution.${terminal} freezes a turn without a normal stop`, (t) => {
    const m = harness(t)
    m.start("a")
    m.delta("a")
    m.advance(1000)
    m.textEnd("a")
    m.end("a", 100, "length")
    m.emit(`execution.${terminal}`)
    assert.equal(m.average(), 100)
    m.end("a", 9000)
    m.emit("execution.started")
    m.turn("next", 50)
    assert.equal(m.average(), 50)
  })
}

test("idle fallback never freezes a busy continuation", (t) => {
  const m = harness(t)
  m.start("a")
  m.delta("a")
  m.advance(1000)
  m.textEnd("a")
  m.end("a", 100, "length")
  m.advance(3000)
  m.runTimers()
  assert.doesNotMatch(m.display(), /avg/)
  m.emit("execution.succeeded")
  assert.equal(m.average(), 100)
})

test("idle fallback freezes output without a step.ended event", (t) => {
  const m = harness(t)
  m.start("a")
  m.delta("a")
  m.advance(1000)
  m.textEnd("a")
  m.idle()
  m.advance(3000)
  m.runTimers()
  assert.equal(m.average(), 10)
})

test("provider totals rescale warmed peak and minimum rates", (t) => {
  const m = harness(t)
  const frozen = m.computeFrozen({
    durationMs: 2000, totalEstTokens: 100, maxLiveTps: 60, minLiveTps: 40,
  }, 200)
  assert.equal(frozen.avg, 100)
  assert.equal(frozen.max, 120)
  assert.equal(frozen.min, 80)
})
