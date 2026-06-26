// harness-proxy — Anthropic Messages API -> OpenAI/vLLM translating proxy.
// Replaces the LiteLLM sidecar + claude-shim.js (issue #10). See harness-proxy/PLAN.md.
//
// Step 1 (this file): scaffold only. Routes exist and serve hardcoded stubs so the
// musl->scratch image builds and runs. Real Anthropic<->OpenAI translation, streaming
// SSE, image hoist and the vLLM call arrive in Steps 2-5 (PLAN.md §5).

use axum::{
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::env;

#[tokio::main]
async fn main() {
    // Bind 0.0.0.0:4000 as a standalone container (reachable on the docker network, like the
    // old litellm service). The in-image final deployment can override to 127.0.0.1:4000.
    let bind = env::var("HARNESS_PROXY_BIND").unwrap_or_else(|_| "0.0.0.0:4000".to_string());

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/messages", post(messages))
        .route("/v1/messages/count_tokens", post(count_tokens));

    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .unwrap_or_else(|e| panic!("harness-proxy: cannot bind {bind}: {e}"));
    eprintln!("> harness-proxy listening on {bind} (Step 1 stub — not yet wired to vLLM)");
    axum::serve(listener, app).await.expect("server error");
}

// ponytail: Step 1 stub — hardcoded Anthropic Message. Translation + vLLM call land in Step 2.
async fn messages(Json(_req): Json<Value>) -> Json<Value> {
    Json(json!({
        "id": "msg_stub",
        "type": "message",
        "role": "assistant",
        "model": "harness-proxy-stub",
        "content": [{ "type": "text", "text": "harness-proxy stub — not yet wired to vLLM (PLAN.md step 1)" }],
        "stop_reason": "end_turn",
        "stop_sequence": Value::Null,
        "usage": { "input_tokens": 0, "output_tokens": 0 }
    }))
}

// ponytail: stub. Anthropic's own docs say input_tokens is an estimate, so a rough count is
// spec-compliant; Step 2 swaps in vLLM /tokenize or a chars/4 heuristic.
async fn count_tokens(Json(_req): Json<Value>) -> Json<Value> {
    Json(json!({ "input_tokens": 1 }))
}
