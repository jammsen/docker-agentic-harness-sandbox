# headroom — optional context-compression sidecar (issue #11). Rules-only build: the [proxy] extra
# skips the Kompress ML model and ONNX runtime, so compression is SmartCrusher/structural only.
# All behavior flags live in compose (HEADROOM_* env vars) so tuning needs no rebuild.
FROM python:3.15-slim@sha256:2da676046630d7bf14c6764ae1143dc7fa0377a53f94bf5a642f0b214aca5bce

RUN pip install --no-cache-dir "headroom-ai[proxy]==0.35.0"

# Non-root, matching the other sidecars (uid 1000).
RUN useradd --uid 1000 --create-home headroom
USER headroom

EXPOSE 8787
CMD ["headroom", "proxy", "--host", "0.0.0.0", "--port", "8787"]
