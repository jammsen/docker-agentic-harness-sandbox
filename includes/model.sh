# Model environment — fail fast with a clear message rather than letting
# services start and fail mysteriously at inference time. Concrete model
# defaults live ONLY in compose.yml (x-model-env); this just validates and derives.

setup_model_env() {
    : "${MODEL_URL:?MODEL_URL is not set. Set it in .env or compose.yml, e.g. MODEL_URL=http://<host>:8000/v1}"
    : "${MODEL_ID:?MODEL_ID is not set. Set it in .env or compose.yml (exact id from GET \$MODEL_URL/models)}"
    : "${MODEL_CONTEXT:?MODEL_CONTEXT is not set. Set it in .env or compose.yml (max_model_len from /v1/models)}"
    : "${MODEL_MAX_TOKENS:?MODEL_MAX_TOKENS is not set. Set it in .env or compose.yml}"
    : "${MODEL_VISION:?MODEL_VISION is not set. Set it in .env or compose.yml (true/false: can the primary see images?)}"
    export MODEL_URL MODEL_ID MODEL_CONTEXT MODEL_MAX_TOKENS MODEL_VISION
    export MODEL_NAME="${MODEL_NAME:-$MODEL_ID}"

    # Vision derivation: unset VISION_MODEL_ID means "primary does everything";
    # a set one inherits any missing knobs from the primary.
    if [[ -z "${VISION_MODEL_ID:-}" ]]; then
        export VISION_MODEL_ID="$MODEL_ID"
        export VISION_MODEL_URL="$MODEL_URL"
        export VISION_MODEL_NAME="${VISION_MODEL_NAME:-$MODEL_NAME}"
    else
        export VISION_MODEL_URL="${VISION_MODEL_URL:-$MODEL_URL}"
        export VISION_MODEL_NAME="${VISION_MODEL_NAME:-$VISION_MODEL_ID}"
    fi
    export VISION_MODEL_CONTEXT="${VISION_MODEL_CONTEXT:-$MODEL_CONTEXT}"
    export VISION_MODEL_MAX_TOKENS="${VISION_MODEL_MAX_TOKENS:-$MODEL_MAX_TOKENS}"

    ei "> Model config: primary='$MODEL_ID' @ $MODEL_URL (vision=$MODEL_VISION)"
    if [[ "$VISION_MODEL_ID" != "$MODEL_ID" || "$VISION_MODEL_URL" != "$MODEL_URL" ]]; then
        ei ">               vision='$VISION_MODEL_ID' @ $VISION_MODEL_URL"
    fi
}
