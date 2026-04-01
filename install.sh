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

# Ordered list of known old paths (newest first)
OLD_PATHS=(
  "$HOME/github/hts-ai-stack"
  "$HOME/github/ubuntu-ai-stack"
)

# Offer to migrate from the first old path found, if new path doesn't exist yet
if [ ! -d "$CLONE_DIR" ]; then
  for OLD_CLONE_DIR in "${OLD_PATHS[@]}"; do
    if [ -d "$OLD_CLONE_DIR/.git" ]; then
      echo ""
      echo "[INFO] Found existing install at old path: $OLD_CLONE_DIR"
      echo "       New path: $CLONE_DIR"
      echo ""
      read -r -p "Migrate it now? [Y/n] " migrate
      migrate="${migrate:-Y}"
      if [[ "$migrate" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "$CLONE_DIR")"
        mv "$OLD_CLONE_DIR" "$CLONE_DIR"
        echo "[OK] Moved $OLD_CLONE_DIR → $CLONE_DIR"
        # Clean up old parent dir if now empty
        rmdir "$(dirname "$OLD_CLONE_DIR")" 2>/dev/null && echo "[INFO] Removed empty $(dirname "$OLD_CLONE_DIR")" || true
      else
        echo "[INFO] Skipping migration — using old path as-is"
        CLONE_DIR="$OLD_CLONE_DIR"
      fi
      break
    fi
  done
fi

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

# Verify the repo is present and has expected structure
if [ ! -f "$CLONE_DIR/install.sh" ]; then
  echo ""
  echo "[ERROR] Clone appears incomplete — install.sh not found in $CLONE_DIR"
  echo ""
  echo "  Download the latest zip manually:"
  echo "  → https://highlytechnicalshit.com"
  echo ""
  echo "  Scroll to 'You must choose carefully how to wield it.'"
  echo "  and click the 'Default Deny' button to download the zip."
  echo ""
  read -r -p "Press Enter once the download is complete..."

  DOWNLOADS_DIR="$HOME/Downloads"
  ZIP_FILE=$(find "$DOWNLOADS_DIR" -maxdepth 1 -name "hts-ai-stack*.zip" -printf "%T@ %p\n" 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

  if [ -z "$ZIP_FILE" ]; then
    echo ""
    echo "[ERROR] No hts-ai-stack*.zip found in $DOWNLOADS_DIR"
    echo "  Please move the downloaded zip there and re-run bootstrap.sh"
    exit 1
  fi

  echo "[INFO] Found: $ZIP_FILE"
  echo "[INFO] Extracting to $(dirname "$CLONE_DIR") ..."
  mkdir -p "$(dirname "$CLONE_DIR")"
  unzip -q "$ZIP_FILE" -d "$(dirname "$CLONE_DIR")"

  # GitHub zips extract to a subdirectory like hts-ai-stack-main — normalise it
  EXTRACTED=$(find "$(dirname "$CLONE_DIR")" -maxdepth 1 -type d -name "hts-ai-stack*" ! -path "$CLONE_DIR" | head -1)
  if [ -n "$EXTRACTED" ] && [ "$EXTRACTED" != "$CLONE_DIR" ]; then
    mv "$EXTRACTED" "$CLONE_DIR"
  fi

  if [ ! -f "$CLONE_DIR/install.sh" ]; then
    echo "[ERROR] Extraction failed — install.sh still not found in $CLONE_DIR"
    exit 1
  fi

  echo "[OK] Extracted successfully to $CLONE_DIR"
fi

echo "[OK] Repo ready at $CLONE_DIR"
echo ""

read -r -p "Run install.sh now? [Y/n] " response
response="${response:-Y}"
if [[ "$response" =~ ^[Yy]$ ]]; then
  cd "$CLONE_DIR"
  exec bash ./install.sh "$@"
else
  echo "[INFO] Skipping install. To run later:"
  echo "  cd $CLONE_DIR && ./install.sh"
fi
