# Ubuntu AI Stack

A self-hosted AI workstation on Ubuntu 24.04 with GPU acceleration. Runs local LLM inference, image generation, voice synthesis, speech recognition, and a sandboxed agent runtime — all in Docker.

## Stack

| Service | URL | Description |
|---|---|---|
| Dashboard | http://localhost | Links to all services — auto-adapts to any hostname |
| Open WebUI | http://localhost:3000 | Chat UI for Ollama / llama-swap |
| Ollama | http://localhost:11434 | GPU LLM inference engine |
| llama-swap | http://localhost:8081 | Unified LLM router (Ollama GPU + BitNet CPU) |
| NemoClaw | http://localhost:8080 | Agent sandbox runtime (OpenShell cluster) |

Default model: `smollm2:135m`

---

## Setup

Start with [00-bootstrap.md](00-bootstrap.md) — gets from a bare machine to a
cloned repo (Firefox, GitHub auth, clone, Docker, NVIDIA drivers + reboot).

After reboot, run `install.sh`:

```bash
cd ~/hts/hts-ai-stack && ./install.sh
```

`install.sh` runs the interactive wizard to configure your stack, applies the
configuration, runs remaining host setup (Node.js, dev tools), then calls
`converge.sh` to deploy all enabled Docker services.

### Day-2 changes

```bash
./scripts/utils/reconfigure.sh            # re-run wizard + converge
./scripts/utils/reconfigure.sh --converge # converge only (use existing config)
./scripts/utils/converge.sh --yes         # standalone convergence
./scripts/utils/converge.sh --dry-run     # preview what would change
```

## Check-in Checks

Repo-local commit checks live under `tests/` and `.githooks/`.

```bash
pwsh -NoLogo -NoProfile -File tests/Invoke-RepoChecks.ps1
pwsh -NoLogo -NoProfile -File tests/Invoke-RepoChecks.ps1 -All
```

Checks run on staged files during `git commit` once hooks are installed:

```bash
pwsh -NoLogo -NoProfile -File tests/Install-GitHooks.ps1
```

Current checks:

| Check | Tool |
| --- | --- |
| Markdown lint | `markdownlint-cli2` via Node/NPM |
| Shell syntax | `bash -n` |
| Shell lint | `shellcheck` when installed |
| Config parse | `node` with JSON/YAML parsers |

### Legacy pipeline scripts (reference only)

> The numbered pipeline scripts (`01-autoinstall.sh` through `07-setup-connectivity.sh`)
> are legacy. `install.sh` now calls `converge.sh` directly for all service deployment.
> These scripts remain in the repo for reference and individual troubleshooting.

| Script | Purpose | Current status |
|--------|---------|----------------|
| `01-autoinstall.sh` | NVIDIA drivers, CUDA, Docker, Node.js | Handled by `bootstrap.sh` + `install.sh` host prereqs |
| `02-setup-docker.sh` | Docker stack startup | Handled by `converge.sh` |
| `03-setup-models.sh` | Ollama model pulls | Handled by component scripts via `converge.sh` |
| `04-setup-nemoclaw.sh` | NemoClaw sandbox | Handled by `converge.sh` |
| `06-start-stack.sh` | Start all services | **Deleted — replaced by `converge.sh`** |
| `07-setup-connectivity.sh` | Tailscale, Signal, Telegram | Handled by `converge.sh` |

---

## Optional — Tooling

### HeidiSQL

```bash
./scripts/install/tooling/install-heidisql.sh
```

Installs HeidiSQL GUI database client on Ubuntu 24.04. Run on your workstation,
not the AI server. Handles the `libqt6pas` dependency automatically.

See [scripts/install/tooling/install-heidisql.md](scripts/install/tooling/install-heidisql.md) for details.

---

### LM Studio

```bash
./scripts/install/tooling/install-lmstudio.sh
```

Installs LM Studio as an alternative local model runner and chat UI.
The setup wizard (`install.sh`) can enable LM Studio during configuration —
it is installed as a host-level `.deb` package (not managed by converge.sh).

See [scripts/install/tooling/install-lmstudio.md](scripts/install/tooling/install-lmstudio.md) for details.

---

## Optional — Alternates

### Docker Model Engine

```bash
./docs/guides/install-docker-model-engine.md
```

Docker's built-in model runner (`docker model run`). Covered by Ollama in the
main stack — retained here as a reference alternative.

---

## Models

See [03-setup-models.md](03-setup-models.md) for model configuration details.

---

## Common Commands

```bash
# Start / stop the stack
docker compose up -d
docker compose down

# Follow logs for a service
docker compose logs -f openclaw

# Restart a single service
docker compose restart openclaw

# Pull a new Ollama model
docker exec -it hts-ai-ollama-gpu ollama pull <model-name>

# Approve OpenClaw browser pairing (required on first connect)
sudo docker exec openclaw openclaw devices approve --latest

# Switch OpenClaw model on a running instance
docker exec openclaw node -e "
  const fs = require('fs'), p = '/home/node/.openclaw/openclaw.json';
  const c = JSON.parse(fs.readFileSync(p));
  c.agents.defaults.model.primary = 'ollama/smollm2:135m';
  fs.writeFileSync(p, JSON.stringify(c, null, 2));
" && docker compose restart openclaw

# NemoClaw — connect to sandbox
nemoclaw hts-ai-assistant connect

# NemoClaw — check status
nemoclaw hts-ai-assistant status
```
