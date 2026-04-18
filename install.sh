#!/usr/bin/env bash
# install.sh — AI Stack installer / re-installer
#
# Flow:
#   1. Resolve repo dir
#   2. Back up config/stack.json + .env to config/backups/YYYYMMDD-HHMMSS/
#   3. If no config/stack.json: run setup menu (required first time)
#      If config exists: ask whether to reconfigure or use existing
#   4. Apply config/stack.json to .env via apply_config.sh
#   5. Host prerequisites (docker, node, tools — idempotent; NVIDIA in bootstrap.sh)
#   6. Stack convergence via converge.sh (all Docker services)
#
# Prerequisites:
#   bootstrap.sh must have run first (installs Docker, NVIDIA drivers, reboots).
#
# Flags:
#   --reconfigure      Always run setup menu even if config exists
#   --skip-config      Skip setup wizard; still applies stack.json → .env
#   --nuke-and-pave    Destroy the stack then rebuild from existing config
#   --dry-run          Print actions without executing install scripts
#   -h, --help         Show this help
#
# Nuke & Pave (drift removal):
#   ./install.sh --nuke-and-pave
#   → destroys all containers, volumes, and runtime state, clears the
#     install manifest, then performs a full reinstall using existing
#     config/stack.json. Equivalent to: nuke-stack.sh && install.sh
#   The interactive menu offers [r] Reset menu (nuke / pave / wipe).
#
# Post-reinstall recovery (NAS / nuke-and-pave):
#   git clone <repo> && cd hts-ai-stack
#   ./install.sh --skip-config
#   → restores /etc/fstab NFS mounts, /etc/idmapd.conf, and stack from
#     config/stack.json without re-running the setup wizard.
#   Prerequisite: DHCP reservation set on router so machine keeps same IP
#   (Synology NFS allowlist is IP-specific — different IP = access denied).

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

# LOG_FILE is set after REPO_DIR is resolved (see below); functions reference it by name.
_log()   { echo "[$(date '+%F %T')] [$1] $2" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true; }
info()   { echo -e "${GREEN}[INFO]${NC} $*"; _log INFO "$*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; _log WARN "$*"; }
fail()   { echo -e "${RED}[FAIL]${NC} $*"; [[ -n "${LOG_FILE:-}" ]] && echo -e "${RED}[FAIL]${NC} See log: $LOG_FILE"; _log FAIL "$*"; exit 1; }
step()   { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; _log STEP "══ $* ══"; }
banner() {
  echo -e "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║        AI STACK — INSTALLER                         ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}\n"
  _log INFO "=== AI STACK INSTALLER STARTED ==="
}

# Detect if the repo is still checked out with the old directory name and offer to rename it.
_check_repo_dir_name() {
  [[ "$(basename "$REPO_DIR")" == "ubuntu-ai-stack" ]] || return 0
  local parent new_dir
  parent="$(dirname "$REPO_DIR")"
  new_dir="$parent/hts-ai-stack"
  echo -e "\n${YELLOW}[WARN]${NC} This repo is checked out as ${BOLD}ubuntu-ai-stack${NC} (old name)."
  echo -e "       The project has been renamed to ${BOLD}hts-ai-stack${NC}."
  echo -e "       Proposed new path: ${BOLD}${new_dir}${NC}\n"
  if [[ -d "$new_dir" ]]; then
    warn "Cannot rename: $new_dir already exists. Continuing with old directory name."
    return 0
  fi
  local _do_rename="no"
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "Rename Repository Directory" \
      --yesno "This repo is checked out as ubuntu-ai-stack (old name).\nThe project has been renamed to hts-ai-stack.\n\nRename directory now?\n\n  $REPO_DIR\n  → $new_dir" 14 70 \
      3>&1 1>&2 2>&3 && _do_rename="yes"
  else
    printf "Rename directory now? [Y/n] "
    local ans; IFS= read -r ans; ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy] ]] && _do_rename="yes"
  fi
  if [[ "$_do_rename" == "yes" ]]; then
    mv "$REPO_DIR" "$new_dir"
    REPO_DIR="$new_dir"
    info "Directory renamed → $REPO_DIR"
    warn "Reminder: update your VS Code workspace, shell bookmarks, and git remote URL."
    warn "  git remote set-url origin https://github.com/htsainet/hts-ai-stack.git"
  else
    info "Skipped rename — continuing from existing path."
  fi
}

# ── Flags ─────────────────────────────────────────────────────────────────────
RECONFIGURE=false
SKIP_CONFIG=false
NUKE_AND_PAVE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure)     RECONFIGURE=true;    shift ;;
    --skip-config)     SKIP_CONFIG=true;     shift ;;
    --nuke-and-pave)   NUKE_AND_PAVE=true;  shift ;;
    --dry-run)         DRY_RUN=true;        shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# ── Locate repo ───────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hts-ai-stack"
if [ -f "$REPO_CONFIG_DIR/clone-path" ]; then
  REPO_DIR=$(cat "$REPO_CONFIG_DIR/clone-path")
fi
[ -d "$REPO_DIR" ] || fail "Repo directory not found: $REPO_DIR"
_check_repo_dir_name

# ── Logging ───────────────────────────────────────────────────────────────────
_LOG_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/ai-stack/install-${_LOG_STAMP}.log"
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
  LOG_FILE="$REPO_DIR/logs/install-${_LOG_STAMP}.log"
  mkdir -p "$(dirname "$LOG_FILE")"
fi
echo "Logging to: $LOG_FILE"
trap '_log ERROR "Unexpected failure at line $LINENO (exit $?)"' ERR

CONFIG_DIR="$REPO_DIR/config"
BACKUP_BASE="$CONFIG_DIR/backups"
STACK_JSON="$CONFIG_DIR/stack.json"
ENV_FILE="$REPO_DIR/.env"
SETUP_MENU="$REPO_DIR/config/wizard/ai_stack_setup.sh"
APPLY_SCRIPT="$REPO_DIR/config/wizard/apply_config.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────
ensure_env_var_set() {
  local key="$1"
  if [ ! -f "$ENV_FILE" ]; then
    fail ".env is missing. Run ./01-autoinstall.sh first."
  fi
  if ! grep -Eq "^${key}=[^[:space:]].*" "$ENV_FILE"; then
    fail "${key} is missing or empty in .env. Run ./01-autoinstall.sh to repair tokens."
  fi
}


run_reset_stack() {
  local reset_script="$REPO_DIR/nuke-stack.sh"

  [ -x "$reset_script" ] || fail "No reset script found: $reset_script"

  warn "Nuke stack selected — this is destructive and will prompt for confirmation."
  local rc=0
  "$reset_script" || rc=$?
  if [[ $rc -eq 130 ]]; then
    warn "Nuke cancelled by user."
    return 1
  elif [[ $rc -ne 0 ]]; then
    fail "Stack destruction failed (exit $rc)."
  fi
  info "Stack destruction completed."
}

# ── Main ──────────────────────────────────────────────────────────────────────
banner
echo -e "${RED}${BOLD}  ⚠  THIS IS A BETA BUILD${NC}"
echo -e "${RED}  ⚠  BACKUPS TO NAS ARE PLANNED FOR A FUTURE RELEASE${NC}"
echo -e "${RED}  ⚠  BACKUP EVERYTHING YOURSELF BEFORE RUNNING IF THERE IS${NC}"
echo -e "${RED}  ⚠  ANY DATA OF VALUE ON THIS UBUNTU INSTANCE${NC}"
echo ""

# ── Step 0 (optional): Nuke & Pave ───────────────────────────────────────────
if "$NUKE_AND_PAVE"; then
  if ! run_reset_stack; then
    info "Nuke cancelled — skipping pave."
    exit 0
  fi
  info "Clearing install manifest for clean pave..."
  rm -f "$REPO_DIR/logs/manifest.json"
fi

# ── Step 1: Backup existing config ────────────────────────────────────────────
step "Config backup"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_BASE"

if [ -f "$STACK_JSON" ]; then
  BACKUP_SLOT="$BACKUP_BASE/$TIMESTAMP"
  mkdir -p "$BACKUP_SLOT"
  cp "$STACK_JSON" "$BACKUP_SLOT/stack.json"
  info "stack.json backed up → config/backups/$TIMESTAMP/"
  # .env backup (gitignored per config/.gitignore)
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$BACKUP_SLOT/.env.bak"
    info ".env backed up      → config/backups/$TIMESTAMP/.env.bak"
  fi
else
  info "No existing config/stack.json — first-time install"
fi

# ── Step 2: Configure ─────────────────────────────────────────────────────────
if ! "$SKIP_CONFIG"; then
  step "Configuration"

  RUN_MENU=false

  if [ ! -f "$STACK_JSON" ]; then
    info "No config found — launching setup menu (required)"
    RUN_MENU=true
  elif "$RECONFIGURE"; then
    info "--reconfigure flag set — launching setup menu"
    RUN_MENU=true
  elif "$NUKE_AND_PAVE"; then
    info "Nuke & Pave — using existing config for reinstall"
  else
    warn "Existing config found: config/stack.json"
    warn "  Last saved: $(python3 -c "import json; d=json.load(open('$STACK_JSON')); print(d.get('_meta',{}).get('saved_at','(default — never customised)'))" 2>/dev/null || echo '(unreadable)')"
    echo ""

    _installer_menu_choice=""
    if command -v whiptail >/dev/null 2>&1; then
      _installer_menu_choice=$(whiptail --title "AI Stack — Existing Config Found" \
        --menu "config/stack.json already exists.\nChoose an action:" 16 60 4 \
        "c" "Reconfigure  — re-run setup wizard" \
        "s" "Skip         — use existing config" \
        "r" "Reset menu   — nuke / pave / wipe" \
        "q" "Quit" \
        3>&1 1>&2 2>&3) || { echo "Aborted."; exit 0; }
    else
      while true; do
        read -rp "  [c] Reconfigure  [s] Skip (use existing)  [r] Reset menu  [q] Quit  → " _installer_menu_choice
        case "${_installer_menu_choice,,}" in
          c|s|r|q) break ;;
          *) warn "Invalid choice — enter c, s, r, or q" ;;
        esac
      done
    fi

    case "${_installer_menu_choice,,}" in
      c) RUN_MENU=true ;;
      s) info "Using existing config" ;;
      r) if [[ -x "$REPO_DIR/scripts/utils/reset-menu.py" ]]; then
           python3 "$REPO_DIR/scripts/utils/reset-menu.py"
         else
           run_reset_stack || warn "Reset cancelled."
         fi
         exit 0 ;;
      q) echo "Aborted."; exit 0 ;;
    esac
  fi

  if "$RUN_MENU"; then
    [ -f "$SETUP_MENU" ] || fail "Setup menu not found: $SETUP_MENU"
    # Clean up any stale .venv left by old Python-based approach
    VENV_DIR="$(dirname "$SETUP_MENU")/.venv"
    [ -d "$VENV_DIR" ] && rm -rf "$VENV_DIR" && info "Removed stale .venv"
    # Pre-scan for existing services so the wizard can pre-fill sensible defaults
    if [ -f "$REPO_DIR/scripts/install/00-check-conflicts.sh" ]; then
      bash "$REPO_DIR/scripts/install/00-check-conflicts.sh" --detect-only 2>/dev/null || true
    fi
    bash "$SETUP_MENU"
  fi
fi

# ── Step 3: Apply config → .env ───────────────────────────────────────────────
# Always runs — even with --skip-config (skips wizard, not apply).
if [ -f "$STACK_JSON" ]; then
  step "Apply config/stack.json → .env"
  [ -x "$APPLY_SCRIPT" ] || fail "apply_config.sh not found or not executable: $APPLY_SCRIPT"
  if "$DRY_RUN"; then
    info "[dry-run] would run: apply_config.sh $STACK_JSON"
  else
    "$APPLY_SCRIPT" "$STACK_JSON" --env-file "$ENV_FILE"
  fi
else
  fail "config/stack.json missing. Run ./install.sh to configure first."
fi

# ── Step 4: Host prerequisites (idempotent — bootstrap handles most on first run) ─
step "Host prerequisites"

# Sudo keep-alive for unattended install
_SUDO_KEEPALIVE=$(python3 -c "
import json, sys
try:
    d = json.load(open('$STACK_JSON'))
    print('true' if d.get('admin',{}).get('sudo_keepalive') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

if [[ "$_SUDO_KEEPALIVE" == "true" ]]; then
  info "Sudo keep-alive enabled — requesting credentials once."
  sudo -v
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  _SUDO_PID=$!
  trap 'kill $_SUDO_PID 2>/dev/null' EXIT
fi

if ! "$DRY_RUN"; then
  # NVIDIA drivers + CUDA handled by bootstrap.sh (always last — requires reboot)
  bash "$REPO_DIR/scripts/host/docker.sh"   # idempotent — bootstrap already ran this
  bash "$REPO_DIR/scripts/host/node.sh"     # NVM + Node.js
  bash "$REPO_DIR/scripts/host/tools.sh"    # jq, .env tokens, backend config (dev tools gated by stack.json)
else
  info "[dry-run] would run: docker.sh, node.sh, tools.sh"
fi

# ── Step 5: Validate .env tokens ─────────────────────────────────────────────
step "Preflight — validate .env"
ensure_env_var_set "WEBUI_SECRET_KEY"
info ".env tokens present"

# ── Step 6: Stack convergence ─────────────────────────────────────────────────
step "Stack convergence"

if "$DRY_RUN"; then
  info "[dry-run] would run: converge.sh --yes"
else
  bash "$REPO_DIR/scripts/utils/converge.sh" --yes
fi

# Post-converge: load default chat model
if ! "$DRY_RUN"; then
  step "Chat mode"
  bash "$REPO_DIR/scripts/components/ollama/ollama.sh" --swap "mean" || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "All installation steps completed successfully!"
_log INFO "=== AI STACK INSTALLER COMPLETE ==="
echo ""
step "What's Next?"
info "Your AI stack is now deployed. Here are your next steps:"
echo ""
echo "  1. View the dashboard:"
echo "     → http://localhost:80"
echo ""
echo "  2. LLM router (dual-inference):"
echo "     → http://localhost:8080      (llama-swap API)"
echo "     → http://localhost:8080/ui   (llama-swap dashboard)"
echo ""
echo "  3. Reconfigure at any time:"
echo "     → ./install.sh --reconfigure"
echo ""
echo "  4. Check host alignment (detect drift):"
echo "     → $REPO_DIR/scripts/utils/check-host-alignment.sh"
echo ""
echo "  5. Reset menu (nuke / pave / wipe & reload):"
echo "     → python3 $REPO_DIR/scripts/utils/reset-menu.py"
echo "     → ./install.sh --nuke-and-pave   (CLI shortcut: nuke + reinstall)"
echo ""
echo "  6. Review config history:"
echo "     → ls config/backups/"
echo ""
echo "  7. Verify the stack:"
echo "     → $REPO_DIR/scripts/utils/verify.sh"
echo ""
echo "  8. Stop the stack:"
echo "     → $REPO_DIR/scripts/utils/teardown.sh"
echo ""
echo "  For more info, see: $REPO_DIR/README.md"
echo ""
