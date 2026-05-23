#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup.sh [options]

Remove all generated OpenCode sandbox state from:
  - workspace/
  - data/

The script preserves:
  - workspace/.gitkeep
  - data/.gitkeep

Options:
  -y, --yes     Run without the interactive confirmation prompt.
  -h, --help    Show this help message.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

confirm_cleanup() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return
  fi

  cat <<EOF
This will delete all generated OpenCode sandbox state under:
  $ROOT_DIR/workspace/
  $ROOT_DIR/data/

Only these placeholder files will be preserved:
  $ROOT_DIR/workspace/.gitkeep
  $ROOT_DIR/data/.gitkeep

This cannot be undone.
EOF

  read -r -p "Do you want to proceed? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cleanup cancelled."
      exit 0
      ;;
  esac
}

clean_dir() {
  local dir="$1"
  local keep="$dir/.gitkeep"

  mkdir -p "$dir"
  find "$dir" -mindepth 1 ! -path "$keep" -exec rm -rf {} +
  touch "$keep"
}

confirm_cleanup
clean_dir "$ROOT_DIR/workspace"
clean_dir "$ROOT_DIR/data"

echo "Cleaned workspace/ and data/ while preserving .gitkeep files."
