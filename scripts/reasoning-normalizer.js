#!/usr/bin/env node
// reasoning-normalizer — response-rewriting reverse proxy between LiteLLM and vLLM.
//
// Why this exists:
//   deepseek-v4-flash emits a chunk carrying BOTH delta.reasoning and delta.content — the last
//   reasoning token and the first answer token in a single delta — and no boundary event between
//   reasoning and content (openclaw#95280). LiteLLM then disagrees with itself: it picks the block
//   type from the raw chunk (sees content -> opens a text block) but translates the delta
//   separately (sees reasoning -> emits a thinking_delta). The thinking delta lands in a text block
//   and Claude Code's SDK aborts the turn with "Content block is not a thinking block".
//
//   Splitting that chunk in two (reasoning-only, then content-only) makes deepseek look like
//   qwen3.6-35b, which never bundles the two and which every gateway already handles correctly.
//   Measured: 0/20 failures vs 3-6/10 without, with thinking still intact. See
//   ideas/deepseek-thinking-block-bug.md.
//
//   Everything else — non-SSE responses, other paths, all requests — is proxied verbatim.
//
// Pure Node stdlib (no deps), matching claude-shim.js. Listens on 127.0.0.1:NORMALIZER_PORT and
// forwards to VLLM_UPSTREAM.

const http = require('http');
const https = require('https');
const { URL } = require('url');

const PORT = parseInt(process.env.NORMALIZER_PORT || '4002', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '600000', 10); // LLM inference is slow
const UPSTREAM = new URL(process.env.VLLM_UPSTREAM || 'http://127.0.0.1:8000');

// Split one `data: {...}` line into reasoning-only + content-only lines when it carries both.
// Returns null when the line needs no rewrite, so the common path forwards bytes untouched.
function splitDualDelta(line) {
  const payload = line.startsWith('data: ') ? line.slice(6).trim() : null;
  if (!payload || payload === '[DONE]') return null;

  let parsed;
  try { parsed = JSON.parse(payload); } catch { return null; }
  const delta = parsed?.choices?.[0]?.delta;
  if (!delta || !delta.reasoning || !delta.content) return null;

  const reasoningOnly = JSON.parse(payload);
  const contentOnly = JSON.parse(payload);
  delete reasoningOnly.choices[0].delta.content;
  // finish_reason belongs with the content half — the reasoning half is not the end of the turn.
  reasoningOnly.choices[0].finish_reason = null;
  delete contentOnly.choices[0].delta.reasoning;
  return `data: ${JSON.stringify(reasoningOnly)}\ndata: ${JSON.stringify(contentOnly)}\n`;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const headers = { ...req.headers, host: UPSTREAM.host };
    delete headers['transfer-encoding'];

    const transport = UPSTREAM.protocol === 'https:' ? https : http;
    const defaultPort = UPSTREAM.protocol === 'https:' ? 443 : 80;
    let timedOut = false;

    const upstreamReq = transport.request(
      {
        hostname: UPSTREAM.hostname,
        port: parseInt(UPSTREAM.port || defaultPort, 10),
        method: req.method,
        path: req.url,
        headers,
      },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);

        // Only SSE needs line-wise inspection; anything else streams through untouched.
        if (!String(upstreamRes.headers['content-type'] || '').includes('text/event-stream')) {
          upstreamRes.pipe(res);
          return;
        }

        let buf = '';
        upstreamRes.setEncoding('utf8');
        upstreamRes.on('data', (d) => {
          buf += d;
          let nl;
          // SSE lines can span chunk boundaries — only process complete lines.
          while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            res.write(splitDualDelta(line) ?? `${line}\n`);
          }
        });
        upstreamRes.on('end', () => { if (buf) res.write(buf); res.end(); });
      }
    );

    upstreamReq.setTimeout(UPSTREAM_TIMEOUT_MS, () => { timedOut = true; upstreamReq.destroy(); });
    upstreamReq.on('error', (err) => {
      if (res.headersSent) { res.end(); return; }
      res.writeHead(timedOut ? 504 : 502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        error: {
          type: timedOut ? 'normalizer_upstream_timeout' : 'normalizer_upstream_error',
          message: timedOut ? `upstream did not respond within ${UPSTREAM_TIMEOUT_MS}ms` : String(err),
        },
      }));
    });

    if (body.length) upstreamReq.write(body);
    upstreamReq.end();
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`> reasoning-normalizer listening on 0.0.0.0:${PORT} → ${UPSTREAM.origin} (splitting dual reasoning+content deltas)`);
});
