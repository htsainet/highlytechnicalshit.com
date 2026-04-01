#!/usr/bin/env bash
# bootstrap.sh — Clone the AI stack repo and launch the installer
#
# Usage (fresh machine):
#   bash <(curl -fsSL https://raw.githubusercontent.com/htsainet/hts-ai-stack/refs/heads/main/bootstrap.sh)
#
# After NVIDIA driver install the script will ask you to reboot.
# Then just run:  cd ~/hts/hts-ai-stack && ./install.sh
set -euo pipefail

CLONE_DIR="${CLONE_DIR:-$HOME/hts/hts-ai-stack}"

if [ -d "$CLONE_DIR/.git" ]; then
  echo "[INFO] Repo already exists at $CLONE_DIR — pulling latest..."
  git -C "$CLONE_DIR" pull --ff-only || true
else
  echo "[INFO] Installing prerequisites..."
  sudo apt-get update -qq
  sudo apt-get install -y git curl

  echo "[INFO] Cloning hts-ai-stack → $CLONE_DIR ..."
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone https://github.com/htsainet/hts-ai-stack.git "$CLONE_DIR"
fi

cd "$CLONE_DIR"
exec bash ./install.sh "$@"
