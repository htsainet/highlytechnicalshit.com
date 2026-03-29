#!/usr/bin/env bash
# install.sh — Run on a fresh Ubuntu 24.04 install, before the repo exists.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/htsainet/highlytechnicalshit.com/refs/heads/main/install.sh | bash
#
# What it does:
#   1. Updates apt, installs prerequisites (curl, gpg, chrony, gh), configures NTP and timezone, and pre-seeds docker group membership
#   2. Installs latest Git
#   3. Installs and launches Firefox for browser-based GitHub auth
#   4. Authenticates GitHub CLI via browser/device flow
#   5. Configures git identity (auto-detected from GitHub CLI session)
#   6. Verifies GitHub access
#   7. Clones the repo to ~/github/ubuntu-ai-stack
#   8. NVIDIA Drivers (reboot prompt — always last)
#
# After reboot, run ./01-autoinstall.sh for remaining host setup
# (VS Code, PowerShell, Node.js, Docker, CUDA, .env tokens, etc.)
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $* — already done"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${GREEN}══ $* ══${NC}"; }

CLONE_DIR="$HOME/github/ubuntu-ai-stack"
BOOTSTRAP_TIMEZONE="${BOOTSTRAP_TIMEZONE:-America/New_York}"

launch_firefox() {
  local url="$1"

  if ! command -v firefox >/dev/null 2>&1; then
    warn "Firefox is not installed; skipping browser launch."
    return 0
  fi

  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    warn "No graphical session detected; Firefox launch skipped."
    return 0
  fi

  nohup firefox --new-window "$url" >/dev/null 2>&1 &
  info "Firefox launched: $url"
}

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "1 — Prerequisites"

sudo apt-get update -qq
sudo apt-get install -y -qq curl gpg ca-certificates apt-transport-https software-properties-common openssh-client chrony gh

sudo timedatectl set-timezone "$BOOTSTRAP_TIMEZONE"
info "Timezone set to $BOOTSTRAP_TIMEZONE"

if getent group docker >/dev/null 2>&1; then
  info "docker group already exists."
else
  sudo groupadd docker
  info "Created docker group."
fi

if id -nG "$USER" | grep -qw docker; then
  skip "$USER already configured for docker group"
else
  sudo usermod -aG docker "$USER"
  info "Added $USER to docker group before reboot-dependent setup."
fi

# Uncomment any commented-out NTP server lines in chrony config
sudo sed -i 's/^#\(server .*\)/\1/' /etc/chrony/chrony.conf

# Enable and start chrony (idempotent — restart if already running)
sudo systemctl enable chrony
sudo systemctl restart chrony

info "Prerequisites ready."

# ── Step 2: Git ───────────────────────────────────────────────────────────────
step "2 — Git"

if ! grep -Rqs "ppa.launchpadcontent.net/git-core/ppa/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  info "Adding git-core PPA for latest Git..."
  sudo add-apt-repository -y ppa:git-core/ppa
fi

sudo apt-get update -qq
sudo apt-get install -y -qq git
info "Git installed: $(git --version)"

# ── Step 3: Firefox ───────────────────────────────────────────────────────────
step "3 — Firefox"

sudo apt-get install -y -qq firefox
launch_firefox "https://github.com/login"

# ── Step 4: GitHub auth ───────────────────────────────────────────────────────
step "4 — GitHub auth"

if gh auth status >/dev/null 2>&1; then
  skip "GitHub CLI already authenticated"
else
  info "Starting GitHub CLI browser sign-in..."
  info "Complete the GitHub login flow in your browser, then return here."
  gh auth login --hostname github.com --git-protocol https --web
fi

gh auth setup-git >/dev/null 2>&1 || true
info "GitHub CLI authentication ready."

# Derive identity from authenticated session (overridable via env vars)
GITHUB_USER="${GITHUB_USER:-$(gh api user -q .login)}"
GITHUB_EMAIL="${GITHUB_EMAIL:-${GITHUB_USER}@users.noreply.github.com}"
REPO_SLUG="${GITHUB_USER}/ubuntu-ai-stack"

# ── Step 5: Git identity ──────────────────────────────────────────────────────
step "5 — Git identity"

git config --global user.name  "$GITHUB_USER"
git config --global user.email "$GITHUB_EMAIL"
info "git config: ${GITHUB_USER} <${GITHUB_EMAIL}>"

# ── Step 6: Verify GitHub access ──────────────────────────────────────────────
step "6 — Verify GitHub access"

if gh repo view "$REPO_SLUG" >/dev/null 2>&1; then
  info "GitHub access confirmed for $REPO_SLUG."
else
  fail "GitHub authentication failed or repo is not accessible. Run: gh auth status"
fi

# ── Step 7: Clone repo ────────────────────────────────────────────────────────
step "7 — Clone repo"

if [ -d "$CLONE_DIR/.git" ]; then
  skip "Repo ($CLONE_DIR)"
else
  mkdir -p "$HOME/github"
  info "Cloning ${REPO_SLUG}..."
  gh repo clone "$REPO_SLUG" "$CLONE_DIR"
  info "Cloned to ${CLONE_DIR}."
fi

# ── Step 8: NVIDIA Drivers ────────────────────────────────────────────────────
step "8 — NVIDIA Drivers"

if nvidia-smi &>/dev/null; then
  skip "NVIDIA drivers ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1))"
  echo ""
  info "Drivers already installed. Run ./01-autoinstall.sh to continue setup."
  info "(01-autoinstall.sh handles VS Code, PowerShell, Docker, CUDA, .env tokens, and more.)"
else
  info "Refreshing apt metadata before driver install..."
  sudo apt-get update -qq

  info "Removing existing NVIDIA packages..."
  sudo apt remove --purge nvidia* -y 2>/dev/null || true

  info "Installing ubuntu-drivers-common..."
  sudo apt install -y ubuntu-drivers-common

  info "Auto-installing best NVIDIA driver..."
  sudo ubuntu-drivers autoinstall

  info "Blacklisting nouveau..."
  sudo bash -c 'echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf'
  sudo update-initramfs -u

  echo ""
  warn "NVIDIA drivers installed. A REBOOT is required."
  warn "After reboot, run: cd ~/github/ubuntu-ai-stack && ./01-autoinstall.sh"
  echo ""
  read -r -p "Reboot now? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    sudo reboot
  else
    warn "Remember to reboot before running 01-autoinstall.sh."
  fi
fi
