#!/usr/bin/env bash
# install.sh — AI Stack installer / re-installer
#
# Flow:
#   1. Resolve repo dir
#   2. Back up config/stack.json + .env to config/backups/YYYYMMDD-HHMMSS/
#   3. If no config/stack.json: run setup menu (required first time)
#      If config exists: ask whether to reconfigure or use existing
#   4. Apply config/stack.json to .env via apply_config.sh
#   5. Host prerequisites via preflight.sh (nvidia CTK, docker, node, tools — idempotent)
#   6. Stack convergence via converge.sh (all Docker services)
#   7. Model warm-up (pull + load default model)
#   8. Background pull of larger models for llama-swap routing
#
# Prerequisites:
#   bootstrap.sh must have run first (installs Docker, NVIDIA drivers, reboots).
#
# Flags:
#   --reconfigure      Always run setup menu even if config exists
#   --skip-config      Skip setup wizard; still applies stack.json → .env
#   --nuke-and-pave    Destroy the stack then rebuild from existing config
#   --force-rebuild[=svc[,svc...]]
#                      Rebuild locally-built Docker images (--no-cache --pull)
#                      and recreate their containers before convergence. Use
#                      this after editing any docker/*/Dockerfile so the
#                      changes actually land; otherwise converge reuses the
#                      cached image and container.
#                      Without an argument, rebuilds every service that has a
#                      `build:` stanza in docker-compose.yml.
#                      With a comma-separated list, rebuilds only those
#                      services — e.g. --force-rebuild=stable-diffusion
#                      or --force-rebuild=stable-diffusion,comfyui
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

# Early help – prints the usage header (comment block) and exits before any heavy imports.
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    _line_no=0
    while IFS= read -r _line; do
        (( _line_no++ ))
        # Skip shebang and blank line at top
        (( _line_no < 2 )) && continue
        # Stop after the header comment (line ~30)
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

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[FAIL] Do not run as root (or with sudo). This script calls sudo internally where needed." >&2
  exit 1
fi

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

# LOG_FILE is set after REPO_DIR is resolved (see below); functions reference it by name.
_log()   { [[ -w "${LOG_FILE:-}" || -z "${LOG_FILE:-}" ]] && echo "[$(date '+%F %T')] [$1] $2" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true; }
info()   { echo -e "${GREEN}[INFO]${NC} $*"; _log INFO "$*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; _log WARN "$*"; }
fail()   { echo -e "${RED}[FAIL]${NC} $*"; [[ -n "${LOG_FILE:-}" ]] && echo -e "${RED}[FAIL]${NC} See log: $LOG_FILE"; _log FAIL "$*"; exit 1; }
step()   { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; _log STEP "══ $* ══"; }
banner() {
  echo -e "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║                HTS AI Stack Installer                ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}\n"
  _log INFO "=== HTS AI STACK INSTALLER STARTED ==="
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
    warn "  git remote set-url origin https://github.com/htsai-net/hts-ai-stack-release.git"
  else
    info "Skipped rename — continuing from existing path."
  fi
}

# ── Flags ─────────────────────────────────────────────────────────────────────
RECONFIGURE=false
SKIP_CONFIG=false
NUKE_AND_PAVE=false
DRY_RUN=false
FORCE_REBUILD=false
FORCE_REBUILD_SERVICES=""   # empty = all buildable services; otherwise comma-list

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure)     RECONFIGURE=true;    shift ;;
    --skip-config)     SKIP_CONFIG=true;     shift ;;
    --nuke-and-pave)   NUKE_AND_PAVE=true;  shift ;;
    --force-rebuild)   FORCE_REBUILD=true;  shift ;;
    --force-rebuild=*) FORCE_REBUILD=true; FORCE_REBUILD_SERVICES="${1#*=}"; shift ;;
    --dry-run)         DRY_RUN=true;        shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# Export so converge.sh / compose.sh (compose_up) can honor the flag without
# having to thread it through every component script.
if "$FORCE_REBUILD"; then
  export HTS_FORCE_REBUILD=1
fi

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
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="$REPO_DIR/logs/install-${_LOG_STAMP}.log"
  mkdir -p "$(dirname "$LOG_FILE")"
fi
echo "Logging to: $LOG_FILE"
export LOG_FILE
trap '_log ERROR "Unexpected failure at line $LINENO (exit $?)"' ERR

CONFIG_DIR="$REPO_DIR/config"
BACKUP_BASE="$CONFIG_DIR/backups"
STACK_JSON="$CONFIG_DIR/stack.json"
ENV_FILE="$REPO_DIR/.env"
# Ensure .env exists with required defaults (WEBUI_SECRET_KEY and OPENCLAW_TOKEN) for fresh installs
GENERATED_ENV=false
if [ ! -f "$ENV_FILE" ]; then
  info "Generating minimal .env for fresh install"
  mkdir -p "$(dirname "$ENV_FILE")"
  printf "WEBUI_SECRET_KEY=$(openssl rand -hex 32)\nOPENCLAW_TOKEN=$(openssl rand -hex 32)\n" > "$ENV_FILE"
  ok "Created $ENV_FILE with generated secrets"
  GENERATED_ENV=true
fi
# If we just generated a fresh .env, launch the setup wizard automatically
if $GENERATED_ENV; then
  info "Auto‑setting RUN_MENU for fresh install"
  RUN_MENU=true
fi
SETUP_MENU="$REPO_DIR/config/wizard/configure.py"
SETUP_MENU_LEGACY="$REPO_DIR/config/wizard/ai_stack_setup.sh"
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

  # If we just generated a fresh .env earlier, auto‑run the wizard and skip the menu
  if $GENERATED_ENV; then
    info "Auto‑running setup wizard for fresh install"
    RUN_MENU=true
  else
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
fi

  if "$RUN_MENU"; then
    [ -f "$SETUP_MENU" ] || fail "Setup menu not found: $SETUP_MENU"
    python3 "$SETUP_MENU"
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
  bash "$REPO_DIR/scripts/host/preflight.sh"
else
  info "[dry-run] would run: scripts/host/preflight.sh (nvidia, docker, node, tools)"
fi

# ── Step 5: Validate .env tokens ─────────────────────────────────────────────
step "Preflight — validate .env"
ensure_env_var_set "WEBUI_SECRET_KEY"
info ".env tokens present"

# ── Step 5.5: Force rebuild of locally-built images (opt-in) ─────────────────
# When --force-rebuild is passed, rebuild every service with a build: stanza
# using --no-cache so any Dockerfile edits actually land, and remove the
# existing containers so compose_up can recreate them from the new image.
# compose_up itself will then run with --force-recreate (see compose.sh)
# because HTS_FORCE_REBUILD is exported.
if "$FORCE_REBUILD"; then
  step "Force rebuild (locally-built images)"
  if "$DRY_RUN"; then
    info "[dry-run] would: docker compose build --no-cache <buildable services>"
    info "[dry-run] would: docker compose rm -sf <buildable services>"
  else
    # Enumerate services with a build: stanza directly from docker-compose.yml
    # (profile-agnostic). If the user passed --force-rebuild=svc1,svc2, filter
    # to just those — and fail loudly if any requested service is either
    # unknown or not locally-built, so typos don't silently no-op.
    # NOTE: This block requires the Python 'yaml' module (PyYAML). Ensure it is installed (e.g., pip install pyyaml).
_ALL_BUILDABLE=$(python3 - "$REPO_DIR/docker-compose.yml" <<'PYEOF' 2>/dev/null || true
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
svcs = doc.get("services", {}) or {}
print(" ".join(n for n, s in svcs.items() if isinstance(s, dict) and "build" in s))
PYEOF
)
    if [[ -n "$FORCE_REBUILD_SERVICES" ]]; then
      _REQUESTED="${FORCE_REBUILD_SERVICES//,/ }"
      _BUILDABLE=""
      for _svc in $_REQUESTED; do
        if [[ " $_ALL_BUILDABLE " == *" $_svc "* ]]; then
          _BUILDABLE+="${_BUILDABLE:+ }$_svc"
        else
          fail "--force-rebuild: '$_svc' is not a locally-built service. Valid options: $_ALL_BUILDABLE"
        fi
      done
    else
      _BUILDABLE="$_ALL_BUILDABLE"
    fi

    if [[ -z "${_BUILDABLE// }" ]]; then
      warn "No buildable services found — nothing to rebuild."
    else
      # Collect every profile those services use so compose will actually see
      # them. Services with no profile are always visible and need no flags.
      _BUILD_PROFILES=$(python3 - "$REPO_DIR/docker-compose.yml" "$_BUILDABLE" <<'PYEOF' 2>/dev/null || true
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
svcs = doc.get("services", {}) or {}
wanted = set(sys.argv[2].split())
profs = set()
for n, s in svcs.items():
    if n not in wanted or not isinstance(s, dict):
        continue
    for p in (s.get("profiles") or []):
        profs.add(p)
print(" ".join(sorted(profs)))
PYEOF
)
      _PROFILE_ARGS=()
      for _p in $_BUILD_PROFILES; do
        _PROFILE_ARGS+=(--profile "$_p")
      done

      info "Rebuilding (no-cache, --pull): ${_BUILDABLE}"
      # shellcheck disable=SC2086  # intentional word-splitting over service list
      docker compose -f "$REPO_DIR/docker-compose.yml" --env-file "$ENV_FILE" \
        "${_PROFILE_ARGS[@]}" build --no-cache --pull --progress=plain ${_BUILDABLE} \
        2>&1 | tee -a "$LOG_FILE"
      info "Removing old containers so compose_up can recreate them..."
      # shellcheck disable=SC2086
      docker compose -f "$REPO_DIR/docker-compose.yml" --env-file "$ENV_FILE" \
        "${_PROFILE_ARGS[@]}" rm -sf ${_BUILDABLE} 2>&1 | tee -a "$LOG_FILE" || true
    fi
  fi
fi

# ── Step 6: Stack convergence ─────────────────────────────────────────────────
step "Stack convergence"

if "$DRY_RUN"; then
  info "[dry-run] would run: converge.sh --yes"
else
  bash "$REPO_DIR/scripts/utils/converge.sh" --yes
fi

# Post-converge: load default model
if ! "$DRY_RUN"; then
  step "Model warm-up"
  bash "$REPO_DIR/scripts/components/ollama/ollama.sh" --warm || true
fi

# Additional-models prompt: opt the user in to pulling the remaining
# registry.json `env=prod` models (starter already pulled by converge).
# Gated on TTY so piped / CI runs are unchanged. See
# docs/planning/autopilot-mvp-stability-pass.md Task 4.
if ! "$DRY_RUN" && [[ -t 0 && -t 1 ]]; then
  step "Additional models"

  _ADDL_SUMMARY="$(
    OLLAMA_MODEL="${OLLAMA_MODEL:-smollm2:135m}" \
    REGISTRY="$REPO_DIR/scripts/install/models/registry.json" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, sys
path = os.environ["REGISTRY"]
starter = os.environ.get("OLLAMA_MODEL", "")
try:
    with open(path) as fh:
        reg = json.load(fh)
except Exception as e:
    print(f"ERR:registry-unreadable:{e}", end="")
    sys.exit(0)
prod = [m for m in reg.get("ollama", []) if "prod" in (m.get("env") or [])]
extras = [m for m in prod if m.get("model") != starter]
count = len(extras)
total_mb = sum(int(m.get("vram_mb") or 0) for m in extras)
total_gb = total_mb / 1024.0
print(f"{count}|{total_gb:.1f}")
PY
  )"

  if [[ "$_ADDL_SUMMARY" == *"|"* ]]; then
    _ADDL_COUNT="${_ADDL_SUMMARY%|*}"
    _ADDL_SIZE_GB="${_ADDL_SUMMARY#*|}"
    if [[ "$_ADDL_COUNT" -gt 0 ]]; then
      echo ""
      echo "The registry has $_ADDL_COUNT additional prod models (~${_ADDL_SIZE_GB} GB"
      echo "approx VRAM footprint) you can pre-stage now so llama-swap can route"
      echo "to them without a cold pull on first use."
      echo ""
      read -r -p "Pull them now in the background? [Y/n] " _addl_reply
      _addl_reply="${_addl_reply:-Y}"
      if [[ "$_addl_reply" =~ ^[Yy]$ ]]; then
        _ADDL_LOG="$REPO_DIR/logs/ollama-background-pull-$(date +%Y%m%d-%H%M%S).log"
        _ADDL_PID="$REPO_DIR/logs/ollama-background-pull.pid"
        mkdir -p "$(dirname "$_ADDL_LOG")"
        nohup "$REPO_DIR/scripts/components/ollama/ollama.sh" --pull-models \
          > "$_ADDL_LOG" 2>&1 &
        disown
        echo $! > "$_ADDL_PID"
        ok "Background pull started (PID $(cat "$_ADDL_PID"))."
        info "Tail progress: tail -f $_ADDL_LOG"
      else
        info "Skipping. To pull later:"
        info "  ./scripts/components/ollama/ollama.sh --pull-models"
      fi
    else
      info "No additional prod models in registry beyond the starter — nothing to pre-stage."
    fi
  else
    warn "Could not read model registry — skipping additional-models prompt."
  fi
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
echo "     → http://localhost:8081      (llama-swap API)"
echo "     → http://localhost:8081/ui   (llama-swap dashboard)"
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
