#!/usr/bin/env node
'use strict';
// test-claude-shim — exercises claude-shim.js end-to-end against a stub upstream.
// Covers the tool_result image hoist and the dual-model vision routing
// (MODEL_VISION=false → image-bearing requests rewritten to the `vision` model).
//
// Usage: node scripts/test-claude-shim.js   (no deps, exits non-zero on failure)

const http = require('http');
const { spawn } = require('child_process');
const path = require('path');

// In-repo the shim lives in ../scripts; the image build overrides with SHIM_PATH=/claude-shim.js.
const SHIM = process.env.SHIM_PATH || path.join(__dirname, '..', 'scripts', 'claude-shim.js');
const UPSTREAM_PORT = 4009;
const SHIM_PORT = 4008;

let lastBody = null;
const upstream = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    lastBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });
});

function post(body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = http.request(
      { hostname: '127.0.0.1', port: SHIM_PORT, path: '/v1/messages', method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } },
      (res) => { res.resume(); res.on('end', resolve); }
    );
    req.on('error', reject);
    req.end(payload);
  });
}

let shimOut = '';
function startShim(env) {
  shimOut = '';
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SHIM], {
      env: { ...process.env, ...env, CLAUDE_SHIM_PORT: String(SHIM_PORT), LITELLM_UPSTREAM: `http://127.0.0.1:${UPSTREAM_PORT}` },
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    child.stdout.on('data', (d) => { shimOut += d; resolve(child); }); // listening banner
  });
}

const IMG = { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } };
let failures = 0;
function check(name, cond) {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}`);
  if (!cond) failures++;
}

(async () => {
  await new Promise((r) => upstream.listen(UPSTREAM_PORT, '127.0.0.1', r));

  // --- dual-model mode: text-only primary --------------------------------
  let shim = await startShim({ MODEL_VISION: 'false' });

  await post({ model: 'brain', messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }] });
  check('text request keeps primary model', lastBody.model === 'brain');

  await post({ model: 'brain', messages: [{ role: 'user', content: [{ type: 'text', text: 'see' }, IMG] }] });
  check('user-message image reroutes to vision', lastBody.model === 'vision');

  await post({ model: 'brain', messages: [{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 't1', content: [{ type: 'text', text: 'read ok' }, IMG] },
  ] }] });
  check('tool_result image reroutes to vision', lastBody.model === 'vision');
  const hoisted = lastBody.messages.length === 2
    && lastBody.messages[0].content[0].content.every((b) => b.type === 'text')
    && lastBody.messages[1].content.some((b) => b.type === 'image');
  check('tool_result image still hoisted to follow-up user message', hoisted);

  await post({ model: 'vision', messages: [{ role: 'user', content: [{ type: 'text', text: 'x' }, IMG] }] });
  check('explicit vision model is respected (no rewrite loop)', lastBody.model === 'vision');

  // Image only in an OLDER turn, newest message is text: the model choice must
  // survive (no pinning to vision) and the stale image gets stripped so the
  // text-only primary can accept the payload.
  const hasAnyImage = (msgs) => msgs.some((m) => Array.isArray(m.content) && m.content.some((b) =>
    (b && b.type === 'image')
    || (b && b.type === 'tool_result' && Array.isArray(b.content) && b.content.some((s) => s && s.type === 'image'))));
  await post({ model: 'brain', messages: [
    { role: 'user', content: [{ type: 'text', text: 'who is this?' }, IMG] },
    { role: 'assistant', content: [{ type: 'text', text: 'Two wrestlers: A and B.' }] },
    { role: 'user', content: [{ type: 'text', text: 'how old are they today?' }] },
  ] });
  check('stale image: explicit brain choice survives', lastBody.model === 'brain');
  check('stale image: image blocks stripped for text-only primary', !hasAnyImage(lastBody.messages));

  // Same history but explicitly addressed to vision: nothing is stripped.
  await post({ model: 'vision', messages: [
    { role: 'user', content: [{ type: 'text', text: 'who is this?' }, IMG] },
    { role: 'assistant', content: [{ type: 'text', text: 'Two wrestlers: A and B.' }] },
    { role: 'user', content: [{ type: 'text', text: 'more detail please' }] },
  ] });
  check('stale image + explicit vision: images kept', lastBody.model === 'vision' && hasAnyImage(lastBody.messages));

  // Old tool_result image (gets hoisted mid-history) + new text turn: still
  // brain, and the hoisted copy is stripped too.
  await post({ model: 'brain', messages: [
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: [{ type: 'text', text: 'read ok' }, IMG] }] },
    { role: 'assistant', content: [{ type: 'text', text: 'Screenshot shows a login page.' }] },
    { role: 'user', content: [{ type: 'text', text: 'write the test plan' }] },
  ] });
  check('stale hoisted tool_result image: stays on brain, stripped', lastBody.model === 'brain' && !hasAnyImage(lastBody.messages));

  // Class slots: haiku/sonnet are vision-side (their backend can see — never
  // reroute or strip), opus/fable are brain-side (same treatment as brain).
  await post({ model: 'haiku', messages: [{ role: 'user', content: [{ type: 'text', text: 'x' }, IMG] }] });
  check('haiku-class with fresh image: not rerouted', lastBody.model === 'haiku');

  await post({ model: 'haiku', messages: [
    { role: 'user', content: [{ type: 'text', text: 'who?' }, IMG] },
    { role: 'assistant', content: [{ type: 'text', text: 'A and B.' }] },
    { role: 'user', content: [{ type: 'text', text: 'more' }] },
  ] });
  check('haiku-class with stale image: images kept', lastBody.model === 'haiku' && hasAnyImage(lastBody.messages));

  await post({ model: 'opus', messages: [{ role: 'user', content: [{ type: 'text', text: 'see' }, IMG] }] });
  check('opus-class with fresh image reroutes to vision', lastBody.model === 'vision');
  await new Promise((r) => setTimeout(r, 150)); // let the stdout pipe deliver the log line
  check('routing log line emitted', shimOut.includes("Req: opus-class called — routing to") && shimOut.includes('rerouted'));

  shim.kill();

  // --- single-model mode: vision-capable primary (default) ---------------
  // Empty string = shim's unset default; plain {} would inherit whatever
  // MODEL_VISION the surrounding container/shell has via ...process.env.
  shim = await startShim({ MODEL_VISION: '' });

  await post({ model: 'brain', messages: [{ role: 'user', content: [{ type: 'text', text: 'see' }, IMG] }] });
  check('MODEL_VISION unset: image request NOT rerouted', lastBody.model === 'brain');

  await post({ model: 'brain', messages: [{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 't1', content: [IMG] },
  ] }] });
  check('MODEL_VISION unset: hoist still active', lastBody.messages.length === 2 && lastBody.model === 'brain');

  shim.kill();
  upstream.close();
  console.log(failures ? `\n${failures} FAILURE(S)` : '\nall checks passed');
  process.exit(failures ? 1 : 0);
})();
