#!/usr/bin/env node
// claude-shim — request-rewriting reverse proxy between Claude Code and LiteLLM.
//
// Why this exists:
//   Claude Code's Read tool delivers images as Anthropic `tool_result` blocks. When LiteLLM
//   translates an Anthropic /v1/messages request to the OpenAI chat/completions format that
//   vLLM speaks, it DROPS images nested inside tool_result blocks (OpenAI tool-role messages
//   cannot carry images). The model then receives an empty tool result and hallucinates.
//
//   This shim rewrites each request before LiteLLM sees it: any image inside a tool_result is
//   lifted out into a fresh user message (a placement vLLM handles correctly), with a text
//   placeholder left in the tool_result so the tool-call/result pairing stays valid. Everything
//   else — including streaming SSE responses and all non-/v1/messages paths — is proxied verbatim.
//
//   Second job (dual-model setups): when the primary model is text-only (MODEL_VISION=false),
//   a request whose NEWEST message carries an image is rerouted to LiteLLM's `vision` model
//   entry (VISION_MODEL_* in compose.yml) so a text-only brain never hallucinates over pixels.
//   Images that only sit in OLDER turns don't hijack the routing: the user's model choice is
//   kept and the stale image blocks are replaced with text placeholders — the vision model's
//   earlier textual analysis is already in the history, which is what the brain works from.
//   Requests already addressed to `vision` pass through untouched.
//
// Pure Node stdlib (no deps), matching upload-server.js. Listens on 127.0.0.1:SHIM_PORT and
// forwards to LITELLM_UPSTREAM (default http://agentic-litellm:4000).

const http  = require('http');
const https = require('https');
const { URL } = require('url');

const SHIM_PORT          = parseInt(process.env.CLAUDE_SHIM_PORT    || '4001',   10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '600000', 10); // 10 min — LLM inference is slow
const UPSTREAM = new URL(process.env.LITELLM_UPSTREAM || 'http://agentic-litellm:4000');

// Vision fallback config — routing rules are described under "Second job" above.
const PRIMARY_HAS_VISION = String(process.env.MODEL_VISION || 'true').toLowerCase() !== 'false';
const VISION_MODEL_ALIAS = process.env.VISION_MODEL_ALIAS || 'vision';

// Model-class slots Claude Code sends (mapped in config/claude/settings.json).
// VISION_SIDE = aliases the litellm config serves from the vision backend —
// must match the model_list split in config/litellm-config.yaml. Requests to
// these may carry images even when the primary is text-only.
const CLASS_SLOTS  = new Set(['haiku', 'sonnet', 'opus', 'fable']);
const VISION_SIDE  = new Set([VISION_MODEL_ALIAS, 'haiku', 'sonnet']);
const BRAIN_ID     = process.env.MODEL_ID || 'brain';
const VISION_ID    = process.env.VISION_MODEL_ID || process.env.MODEL_ID || 'vision';
const backendFor   = (model) => VISION_SIDE.has(model)
  ? { id: VISION_ID, side: 'vision' }
  : { id: BRAIN_ID,  side: 'brain'  };

// --- the rewrite ---------------------------------------------------------
// Walk messages; for every user message, pull image blocks out of tool_result blocks and append
// them in a new user message right after. Returns true if anything changed.
function hoistToolResultImages(body) {
  if (!body || !Array.isArray(body.messages)) return false;
  let changed = false;
  const out = [];
  for (const msg of body.messages) {
    out.push(msg);
    if (!msg || msg.role !== 'user' || !Array.isArray(msg.content)) continue;
    const hoisted = [];
    for (const block of msg.content) {
      if (block && block.type === 'tool_result' && Array.isArray(block.content)) {
        const kept = [];
        for (const sub of block.content) {
          if (sub && sub.type === 'image') {
            hoisted.push(sub);
            kept.push({ type: 'text', text: '[image returned by tool — provided in the next message]' });
            changed = true;
          } else {
            kept.push(sub);
          }
        }
        block.content = kept;
      }
    }
    if (hoisted.length) {
      out.push({
        role: 'user',
        content: [{ type: 'text', text: 'Image(s) returned by the tool call above:' }, ...hoisted],
      });
    }
  }
  if (changed) body.messages = out;
  return changed;
}

// True if one message carries an image block — top-level in a user message or
// nested inside a tool_result. Checked after hoisting, but written to be
// position-independent so it stays correct either way.
function messageHasImage(msg) {
  if (!msg || !Array.isArray(msg.content)) return false;
  for (const block of msg.content) {
    if (!block) continue;
    if (block.type === 'image') return true;
    if (block.type === 'tool_result' && Array.isArray(block.content)
        && block.content.some((sub) => sub && sub.type === 'image')) return true;
  }
  return false;
}

function containsImages(body) {
  if (!body || !Array.isArray(body.messages)) return false;
  return body.messages.some(messageHasImage);
}

// Replace every image block with a text placeholder the text-only primary can
// accept. Returns the number of blocks replaced.
const STRIPPED_IMAGE_NOTE =
  '[image removed — the current model is text-only; the image was analyzed earlier in this conversation]';
function stripImages(body) {
  let stripped = 0;
  const placeholder = () => { stripped++; return { type: 'text', text: STRIPPED_IMAGE_NOTE }; };
  for (const msg of body.messages) {
    if (!msg || !Array.isArray(msg.content)) continue;
    msg.content = msg.content.map((block) => {
      if (block && block.type === 'image') return placeholder();
      if (block && block.type === 'tool_result' && Array.isArray(block.content)) {
        block.content = block.content.map((sub) => (sub && sub.type === 'image') ? placeholder() : sub);
      }
      return block;
    });
  }
  return stripped;
}

// Apply only to JSON requests that carry a `messages` array (/v1/messages and its count_tokens
// variant). Returns a Buffer to forward, or null to forward the original bytes unchanged.
function maybeRewrite(pathname, raw) {
  if (!pathname.startsWith('/v1/messages')) return null;
  let body;
  try { body = JSON.parse(raw.toString('utf8')); } catch { return null; }
  let changed = hoistToolResultImages(body);
  const requested = body.model; // reroute below may rename it — log the original class
  let note = '';
  if (!PRIMARY_HAS_VISION
      && typeof body.model === 'string' && !VISION_SIDE.has(body.model)) {
    const msgs = Array.isArray(body.messages) ? body.messages : [];
    if (messageHasImage(msgs[msgs.length - 1])) {
      // Fresh image in the newest turn — this request is about the image.
      // (Hoisting places a tool_result image into an appended user message,
      // so a just-read image is the last message either way.)
      note = ' — image in newest turn, rerouted to vision';
      body.model = VISION_MODEL_ALIAS;
      changed = true;
    } else if (containsImages(body)) {
      // Images only in older turns: keep the chosen model, drop the stale
      // pixels it cannot accept.
      const stripped = stripImages(body);
      if (stripped) {
        changed = true;
        note = ` — ${stripped} stale image block(s) stripped`;
      }
    }
  }
  // One line per completion request; the noisy count_tokens variant is skipped.
  // Colors match includes/colors.sh: INFO \e[38;5;68m, WARNING \e[93m.
  if (pathname === '/v1/messages' && typeof requested === 'string') {
    const cls = CLASS_SLOTS.has(requested) ? `${requested}-class` : `'${requested}'`;
    const { id, side } = backendFor(body.model);
    const warn = note ? `\x1b[93m${note}\x1b[0m` : '';
    console.log(`\x1b[38;5;68m> Req: ${cls} called — routing to ${id} (${side})\x1b[0m${warn}`);
  }
  if (!changed) return null;
  return Buffer.from(JSON.stringify(body), 'utf8');
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const raw = Buffer.concat(chunks);
    const pathname = req.url.split('?')[0];
    const rewritten = (req.method === 'POST') ? maybeRewrite(pathname, raw) : null;
    const outBody = rewritten || raw;

    const headers = { ...req.headers, host: UPSTREAM.host };
    if (outBody.length || req.method === 'POST') headers['content-length'] = Buffer.byteLength(outBody);
    delete headers['transfer-encoding'];

    const transport = UPSTREAM.protocol === 'https:' ? https : http;
    const defaultPort = UPSTREAM.protocol === 'https:' ? 443 : 80;
    let timedOut = false;
    const upstreamReq = transport.request(
      {
        hostname: UPSTREAM.hostname,
        port:     parseInt(UPSTREAM.port || defaultPort, 10),
        method:   req.method,
        path:     req.url,
        headers,
      },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
        upstreamRes.pipe(res); // streams SSE transparently
      }
    );
    upstreamReq.setTimeout(UPSTREAM_TIMEOUT_MS, () => {
      timedOut = true;
      upstreamReq.destroy();
    });
    upstreamReq.on('error', (err) => {
      if (res.headersSent) { res.end(); return; }
      if (timedOut) {
        res.writeHead(504, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'shim_upstream_timeout', message: `upstream did not respond within ${UPSTREAM_TIMEOUT_MS}ms` } }));
      } else {
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'shim_upstream_error', message: String(err) } }));
      }
    });
    if (outBody.length) upstreamReq.write(outBody);
    upstreamReq.end();
  });
});

server.listen(SHIM_PORT, '127.0.0.1', () => {
  const routing = PRIMARY_HAS_VISION ? '' : `, routing image requests to '${VISION_MODEL_ALIAS}'`;
  console.log(`> claude-shim listening on 127.0.0.1:${SHIM_PORT} → ${UPSTREAM.origin} (hoisting tool_result images${routing})`);
});
