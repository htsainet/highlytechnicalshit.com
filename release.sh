#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="highlytechnicalshit.com"
VERSION=""
OUTPUT_DIR="$SCRIPT_DIR/dist"

usage() {
  cat <<'EOF'
Usage: ./release.sh [--version VERSION] [--name NAME] [--output-dir DIR]

Builds a release zip from git-tracked files at HEAD.

Options:
  --version      Version string in output filename (default: git describe or date)
  --name         Base archive name (default: highlytechnicalshit.com)
  --output-dir   Directory to place zip output (default: ./dist)
  -h, --help     Show this help

Examples:
  ./release.sh
  ./release.sh --version v0.1.0
  ./release.sh --name hts-site --output-dir /tmp/releases
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "[FAIL] --version requires a value" >&2; exit 1; }
      VERSION="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || { echo "[FAIL] --name requires a value" >&2; exit 1; }
      APP_NAME="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "[FAIL] --output-dir requires a value" >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[FAIL] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v git >/dev/null 2>&1; then
  echo "[FAIL] git is required to build the release archive." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[FAIL] Must be run from inside a git repository." >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)"
fi

mkdir -p "$OUTPUT_DIR"
ARCHIVE_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}.zip"

echo "[INFO] Building archive: $ARCHIVE_PATH"
git archive --format=zip --output "$ARCHIVE_PATH" HEAD

echo "[INFO] Release build complete."
echo "[INFO] Archive: $ARCHIVE_PATH"
