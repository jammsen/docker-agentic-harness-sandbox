#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TOOL=""
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool)
            if [[ -n "${2:-}" ]]; then
                DEFAULT_TOOL="$2"
                shift 2
            else
                echo "Error: --tool requires a tool name argument" >&2
                exit 1
            fi
            ;;
        *)
            BUILD_ARGS+=("$1")
            shift
            ;;
    esac
done

docker compose build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"

if [[ -n "$DEFAULT_TOOL" ]]; then
    docker compose run --rm --service-ports -e DEFAULT_TOOL="$DEFAULT_TOOL" sandbox
else
    docker compose run --rm --service-ports sandbox
fi
