#!/usr/bin/env bash
# Early help – prints the usage header (comment block) and exits before any heavy work.
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    _line_no=0
    while IFS= read -r _line; do
        (( _line_no++ ))
        # Skip shebang line and blank line at top
        (( _line_no < 2 )) && continue
        # Stop after the header comment (approx line 30)
        (( _line_no > 30 )) && break
        # Strip leading comment markers
        if [[ "$_line" == "# "* ]]; then
            printf '%s\n' "${_line#\# }"
        elif [[ "$_line" == "#"* ]]; then
            printf '%s\n' "${_line#\#}"
        else
            printf '%s\n' "$_line"
        fi
    done < "${BASH_SOURCE[0]}"
    exit 0
fi
# bootstrap.sh — Fresh machine setup: auth, clone, PowerShell, Docker, NVIDIA
#
# Usage (fresh machine, before repo exists):
#   bash <(curl -fsSL https://raw.githubusercontent.com/htsai-net/hts-ai-stack-release/refs/heads/main/bootstrap.sh)
#
# What it does:
#   1. Installs prerequisites (curl, gpg, git, chrony, gh, Brave browser)
#   2. Authenticates GitHub CLI (browser flow — no password needed)
#   3. Configures git identity from GitHub session
#   4. Clones (or updates) the repo via gh
#   5. Installs PowerShell 7 + Pester (so pre-commit tests work immediately)
#   6. Installs shellcheck (required by Test-RepoChecks shell lint gate)
#   7. Installs Node.js 20 LTS + runs `npm ci` (markdownlint-cli2, cspell,
#      jsonc-parser needed by the Pester repo-checks gate)
#   8. Installs Docker Engine (no NVIDIA dependency — ready after reboot)
#   9. Installs NVIDIA drivers → prompts reboot (always last)
#
# After reboot, run:  cd ~/hts/hts-ai-stack && ./install.sh
# install.sh handles: CUDA toolkit, nvidia-container-toolkit (needs Docker+drivers), stack setup
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[FAIL] Do not run as root (or with sudo). This script calls sudo internally where needed." >&2
  exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $* — already done"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${GREEN}══ $* ══${NC}"; }
ok()   { echo -e "${GREEN}[ OK]${NC} $*"; }

CLONE_DIR="${CLONE_DIR:-$HOME/hts/hts-ai-stack}"
BOOTSTRAP_TIMEZONE="${BOOTSTRAP_TIMEZONE:-America/New_York}"
REPO_SLUG="htsai-net/hts-ai-stack-release"

OLD_PATHS=(
  "$HOME/github/hts-ai-stack"
  "$HOME/github/ubuntu-ai-stack"
)

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "1 — Prerequisites"

# Ensure curl exists first (bare Ubuntu may not have it)
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y curl
fi

# Install gh CLI via official apt source if not present
if ! command -v gh >/dev/null 2>&1; then
  info "Installing GitHub CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" | \
    sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
fi

sudo apt-get update -qq
sudo apt-get install -y -qq curl gpg git chrony ca-certificates apt-transport-https skopeo jq unzip

# Brave browser (real .deb, not snap) — needed for gh auth --web inside xrdp
# GNOME sessions where the Firefox snap fails on the snap cgroup confinement
# check. Installed before Step 2 so the GitHub browser sign-in flow works.
if command -v brave-browser >/dev/null 2>&1; then
  skip "Brave browser ($(brave-browser --version 2>/dev/null | head -1))"
else
  info "Installing Brave browser..."
  curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq brave-browser
  ok "Brave browser installed."
fi

# Desktop shortcut (GNOME — for xrdp users who want a clickable icon)
_brave_src="/usr/share/applications/brave-browser.desktop"
_brave_desktop="$HOME/Desktop/brave-browser.desktop"
if [[ -f "$_brave_src" ]]; then
  mkdir -p "$HOME/Desktop"
  if [[ ! -f "$_brave_desktop" ]]; then
    cp "$_brave_src" "$_brave_desktop"
    chmod +x "$_brave_desktop"
    # GNOME 42+ requires the launcher to be marked trusted
    gio set "$_brave_desktop" metadata::trusted true 2>/dev/null || true
    info "Brave desktop shortcut created at $_brave_desktop"
  fi
fi
unset _brave_src _brave_desktop

sudo timedatectl set-timezone "$BOOTSTRAP_TIMEZONE"
info "Timezone: $BOOTSTRAP_TIMEZONE"

# NTP
sudo sed -i 's/^#\(server .*\)/\1/' /etc/chrony/chrony.conf
sudo systemctl enable --quiet chrony
sudo systemctl restart chrony

ok "Prerequisites ready."

# ── Step 2: GitHub auth ───────────────────────────────────────────────────────
step "2 — GitHub auth"

if gh auth status >/dev/null 2>&1; then
  skip "GitHub CLI already authenticated"
else
  info "Starting GitHub CLI browser sign-in..."
  info "Complete the sign-in flow in your browser, then return here."
  gh auth login --hostname github.com --git-protocol https --web
fi

gh auth setup-git >/dev/null 2>&1 || true
ok "GitHub CLI authenticated."

# ── Step 2b: GitHub Copilot CLI ──────────────────────────────────────────────
# Installed via snap as the standalone copilot-cli agent (invoked as `copilot`).
if snap list copilot-cli &>/dev/null; then
  skip "GitHub Copilot CLI (copilot-cli snap)"
else
  info "Installing GitHub Copilot CLI via snap..."
  sudo snap install copilot-cli
  ok "GitHub Copilot CLI installed — invoke with: copilot"
fi

# ── Step 2c: Obsidian CLI ────────────────────────────────────────────────────
# Obsidian's official CLI for programmatic vault access, headless sync, and
# agentic tool integration. Requires the Obsidian desktop app to be installed.
# See: https://obsidian.md/cli
if command -v obsidian >/dev/null 2>&1; then
  skip "Obsidian CLI already installed"
else
  if command -v snap >/dev/null 2>&1 && snap list obsidian &>/dev/null; then
    info "Obsidian detected via snap — enable CLI in Settings → General → Command line interface"
    info "Then follow on-screen instructions to register the CLI in your PATH."
  elif command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi obsidian; then
    info "Obsidian detected via flatpak — enable CLI in Settings → General → Command line interface"
  else
    info "Obsidian not found — install from https://obsidian.md/download"
    info "After install, enable CLI in Settings → General → Command line interface"
  fi
fi

# ── Step 2d: OpenCode ────────────────────────────────────────────────────────
# Terminal AI coding agent — available immediately after bootstrap without
# waiting for install.sh.  Integrates with local Ollama / llama-swap once the
# stack is running.  Docs: https://opencode.ai/docs
_oc_bin="${HOME}/.opencode/bin/opencode"
if command -v opencode >/dev/null 2>&1 || [[ -x "$_oc_bin" ]]; then
  skip "OpenCode already installed"
else
  info "Installing OpenCode (terminal AI coding agent)..."
  curl -fsSL https://opencode.ai/install | bash
  hash -r 2>/dev/null || true
  if command -v opencode >/dev/null 2>&1 || [[ -x "$_oc_bin" ]]; then
    ok "OpenCode installed."
  else
    warn "opencode not found in PATH — open a new terminal or check ~/.opencode/bin"
  fi
fi
unset _oc_bin

# Pre-configure OpenCode to use the stack's llama-swap router at localhost:8081.
# The canonical filename is opencode.json (current schema). If a stale
# config.json with the old flat schema exists, back it up and remove it so
# opencode stops rejecting it on startup.
_oc_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
_oc_legacy_file="$_oc_config_dir/config.json"
_oc_config_file="$_oc_config_dir/opencode.json"
mkdir -p "$_oc_config_dir"

if [[ -f "$_oc_legacy_file" ]]; then
  _oc_backup="$_oc_legacy_file.legacy.bak"
  if [[ ! -f "$_oc_backup" ]]; then
    cp -p "$_oc_legacy_file" "$_oc_backup"
    info "Backed up legacy opencode config.json → $_oc_backup"
  fi
  rm -f "$_oc_legacy_file"
  unset _oc_backup
fi

if [[ ! -f "$_oc_config_file" ]]; then
  cat > "$_oc_config_file" <<'OCCONF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local (llama-swap)",
      "options": {
        "baseURL": "http://localhost:8081/v1"
      },
      "models": {
        "smollm2:135m":              { "name": "SmolLM2 135M" },
        "qwen2.5:7b-instruct-q4_K_M": { "name": "Qwen2.5 7B Instruct" },
        "bitnet":                    { "name": "BitNet (CPU)" }
      }
    }
  },
  "model": "local/smollm2:135m"
}
OCCONF
  info "Created OpenCode config → llama-swap at localhost:8081"
fi
unset _oc_config_dir _oc_legacy_file _oc_config_file

# ── Step 3: Git identity ──────────────────────────────────────────────────────
step "3 — Git identity"

GITHUB_USER="${GITHUB_USER:-$(gh api user -q .login)}"
GITHUB_EMAIL="${GITHUB_EMAIL:-${GITHUB_USER}@users.noreply.github.com}"

if [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
  git config --global user.name  "$GITHUB_USER"
  git config --global user.email "$GITHUB_EMAIL"
  ok "git config: ${GITHUB_USER} <${GITHUB_EMAIL}>"
else
  skip "git identity ($(git config --global user.name))"
fi

# ── Step 4: Clone / update repo ──────────────────────────────────────────────
step "4 — Clone repo"

# Offer to migrate from first old path found
if [ ! -d "$CLONE_DIR" ]; then
  for OLD_CLONE_DIR in "${OLD_PATHS[@]}"; do
    if [ -d "$OLD_CLONE_DIR/.git" ]; then
      echo ""
      info "Found existing install at old path: $OLD_CLONE_DIR"
      info "New path: $CLONE_DIR"
      read -r -p "Migrate it now? [Y/n] " migrate
      migrate="${migrate:-Y}"
      if [[ "$migrate" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "$CLONE_DIR")"
        mv "$OLD_CLONE_DIR" "$CLONE_DIR"
        ok "Moved $OLD_CLONE_DIR → $CLONE_DIR"
        rmdir "$(dirname "$OLD_CLONE_DIR")" 2>/dev/null && \
          info "Removed empty $(dirname "$OLD_CLONE_DIR")" || true
      else
        info "Skipping migration — using old path as-is"
        CLONE_DIR="$OLD_CLONE_DIR"
      fi
      break
    fi
  done
fi

if [ -d "$CLONE_DIR/.git" ]; then
  skip "Repo at $CLONE_DIR"
  info "Pulling latest..."
  git -C "$CLONE_DIR" pull --ff-only || true
else
  info "Verifying GitHub access..."
  gh repo view "$REPO_SLUG" >/dev/null 2>&1 || \
    fail "Cannot access $REPO_SLUG — check: gh auth status"

  mkdir -p "$(dirname "$CLONE_DIR")"
  info "Cloning ${REPO_SLUG} → $CLONE_DIR ..."
  gh repo clone "$REPO_SLUG" "$CLONE_DIR"
  ok "Cloned to $CLONE_DIR"
fi

# Sanity check
if [ ! -f "$CLONE_DIR/install.sh" ]; then
  echo ""
  warn "Clone appears incomplete — install.sh not found."
  echo ""
  echo "  Download the latest zip manually:"
  echo "  → https://highlytechnicalshit.com"
  echo ""
  read -r -p "Press Enter once the download is complete..."

  DOWNLOADS_DIR="$HOME/Downloads"
  ZIP_FILE=$(find "$DOWNLOADS_DIR" -maxdepth 1 -name "hts-ai-stack*.zip" -printf "%T@ %p\n" 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

  if [ -z "$ZIP_FILE" ]; then
    fail "No hts-ai-stack*.zip found in $DOWNLOADS_DIR — move the zip there and re-run bootstrap.sh"
  fi

  info "Extracting $ZIP_FILE ..."
  mkdir -p "$(dirname "$CLONE_DIR")"
  unzip -q "$ZIP_FILE" -d "$(dirname "$CLONE_DIR")"

  EXTRACTED=$(find "$(dirname "$CLONE_DIR")" -maxdepth 1 -type d -name "hts-ai-stack*" \
    ! -path "$CLONE_DIR" | head -1)
  if [ -n "$EXTRACTED" ] && [ "$EXTRACTED" != "$CLONE_DIR" ]; then
    mv "$EXTRACTED" "$CLONE_DIR"
  fi

  [ -f "$CLONE_DIR/install.sh" ] || fail "Extraction failed — install.sh still not found."
  ok "Extracted successfully to $CLONE_DIR"
fi

ok "Repo ready at $CLONE_DIR"

# ── Step 5: PowerShell + Pester ──────────────────────────────────────────────
step "5 — PowerShell + Pester"

if command -v pwsh &>/dev/null; then
  skip "PowerShell ($(pwsh --version 2>/dev/null | head -1))"
else
  info "Registering Microsoft package repository..."
  # shellcheck source=/dev/null
  source /etc/os-release
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
    -o /tmp/packages-microsoft-prod.deb
  sudo dpkg -i /tmp/packages-microsoft-prod.deb
  rm /tmp/packages-microsoft-prod.deb
  sudo apt-get update -qq
  info "Installing PowerShell..."
  sudo apt-get install -y -qq powershell
  ok "PowerShell installed: $(pwsh --version 2>/dev/null | head -1)"
fi

info "Ensuring Pester module is available..."
pwsh -NoLogo -NoProfile -Command "
  if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  }
  if (-not (Get-Module -ListAvailable -Name Pester)) {
    Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -Repository PSGallery
  }
"
ok "Pester ready"

# ── Step 6: shellcheck ───────────────────────────────────────────────────────
# Required by tests/Test-RepoChecks.Tests.ps1 ('Shell checks: runs shellcheck');
# without it the gate is silently skipped on every pre-commit run.
step "6 — shellcheck"
if command -v shellcheck &>/dev/null; then
  skip "shellcheck ($(shellcheck --version | awk '/^version:/ {print $2}'))"
else
  info "Installing shellcheck..."
  sudo apt-get install -y -qq shellcheck
  ok "shellcheck installed: $(shellcheck --version | awk '/^version:/ {print $2}')"
fi

# ── Step 7: Node.js + repo npm dependencies ─────────────────────────────────
# The Pester repo-checks gate (tests/Test-RepoChecks.Tests.ps1) shells out to
# markdownlint-cli2, cspell, and node (jsonc-parser) via `npx --no-install`.
# Those packages must already be resolved in the repo's node_modules — `npm ci`
# installs them from package-lock.json. Node 20 LTS is pinned to match the
# cspell ^8.x engine constraint.
step "7 — Node.js + npm dependencies"

if command -v node &>/dev/null && node --version 2>/dev/null | grep -qE '^v(20|22)\.'; then
  skip "Node.js ($(node --version))"
else
  info "Installing Node.js 20 LTS via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
  ok "Node.js installed: $(node --version)"
fi

if [[ -f "$CLONE_DIR/package-lock.json" ]]; then
  info "Installing repo npm dependencies (npm ci)..."
  (cd "$CLONE_DIR" && npm ci --no-audit --no-fund --silent)
  ok "npm dependencies installed in $CLONE_DIR/node_modules"
else
  warn "No package-lock.json at $CLONE_DIR — skipping npm ci."
fi

# ── Step 8: Docker Engine ─────────────────────────────────────────────────────
# Install Docker before NVIDIA so that post-reboot nvidia-container-toolkit
# can configure the daemon immediately (it requires Docker to already exist).
step "8 — Docker Engine"
bash "$CLONE_DIR/scripts/host/docker.sh"

# ── Step 9: NVIDIA Drivers ────────────────────────────────────────────────────
step "9 — NVIDIA Drivers"
# nvidia.sh installs drivers and exits (exit 0) if a reboot is required.
# CUDA toolkit + container toolkit run in install.sh AFTER the reboot via
# scripts/host/nvidia.sh (idempotent — skips drivers, proceeds to CUDA+CTK).

# Detect GPU vendor (NVIDIA vs AMD) before invoking NVIDIA setup.
GPU_VENDOR="none"
if command -v lspci &>/dev/null; then
  if lspci -d 10de: &>/dev/null; then
    GPU_VENDOR="nvidia"
  elif lspci -d 1002: &>/dev/null; then
    GPU_VENDOR="amd"
  fi
fi

if [[ "$GPU_VENDOR" == "nvidia" ]]; then
  DRIVERS_WERE_MISSING=false
  nvidia-smi &>/dev/null || DRIVERS_WERE_MISSING=true
  bash "$CLONE_DIR/scripts/host/nvidia.sh"
elif [[ "$GPU_VENDOR" == "amd" ]]; then
  info "AMD GPU detected — handling AMD drivers."
  bash "$CLONE_DIR/scripts/host/amd.sh"
  if [ $? -eq 0 ]; then
    DRIVERS_WERE_MISSING=false
  else
    DRIVERS_WERE_MISSING=true
  fi
else
  info "No GPU detected — skipping NVIDIA driver installation."
  DRIVERS_WERE_MISSING=false
fi

if $DRIVERS_WERE_MISSING; then
  echo ""
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "  REBOOT REQUIRED before continuing."
  warn "  After reboot, run:  cd $CLONE_DIR && ./install.sh"
  warn "  install.sh will handle CUDA toolkit + container toolkit."
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -r -p "Reboot now? [Y/n] " reply
  reply="${reply:-Y}"
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    sudo reboot
  else
    warn "Remember to reboot before running install.sh."
  fi
  exit 0
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
ok "Bootstrap complete. Repo: $CLONE_DIR"
echo ""
read -r -p "Run install.sh now? [Y/n] " response
response="${response:-Y}"
if [[ "$response" =~ ^[Yy]$ ]]; then
  cd "$CLONE_DIR"
  exec bash ./install.sh "$@"
else
  info "To run later:  cd $CLONE_DIR && ./install.sh"
fi
