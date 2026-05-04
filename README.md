# Ubuntu AI Stack

<!-- Release process now auto-updates the website footer date via release-export.sh -->

Self‑hosted AI workstation on Ubuntu 24.04 with GPU acceleration. It runs local LLM inference, image generation, voice synthesis, speech recognition, and a sandboxed agent runtime — all via Docker.

## Quick start (public)

Run the public bootstrap script:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/htsai-net/hts-ai-stack-release/refs/heads/main/bootstrap.sh)
```

Reboot when prompted, then install the stack:

```bash
cd ~/hts/hts-ai-stack && ./install.sh
```

## What you get

| Service | URL | Description |
|---|---|---|
| Dashboard | http://localhost | UI that links to all services |
| Open WebUI | http://localhost:3000 | Chat UI for Ollama / llama‑swap |
| Ollama | http://localhost:11434 | GPU LLM inference engine |
| llama‑swap | http://localhost:8081 | Unified LLM router (GPU + CPU) |
| NemoClaw | http://localhost:8080 | Agent sandbox runtime (OpenShell cluster) |

Default model: `smollm2:135m`

## Installation flow

1. **bootstrap.sh** – Runs on a fresh machine. Installs prerequisites (curl, git, gh, Brave, NTP, etc.), authenticates with GitHub, clones the repo, installs Node .js, Docker, and NVIDIA drivers (last step, requires reboot).
2. **install.sh** – Interactive wizard that generates `config/stack.json`, installs any remaining host tools, and internally runs `converge.sh` to start all services.
3. **reconfigure.sh** – Optional day‑2 helper (`./scripts/utils/reconfigure.sh`) to re‑run the wizard or only re‑converge without reinstalling host prerequisites.

> The legacy `01‑autoinstall.sh`, `02‑setup‑docker.sh`, … scripts are kept for reference only and are **not** used in the current workflow.

## Day‑2 changes

```bash
# Re‑run the wizard and apply any configuration changes
./scripts/utils/reconfigure.sh

# Apply configuration without re‑running the wizard (only re‑converge)
./scripts/utils/reconfigure.sh --converge
```

## Repository checks

The repo includes pre‑commit hooks that enforce:

* Markdown lint (`markdownlint-cli2`)
* Shell syntax (`bash -n`)
* Shell lint (`shellcheck` if installed)
* Config validation (`node` parsers)

Run the full suite with:

```bash
pwsh -NoLogo -NoProfile -File tests/Invoke-RepoChecks.ps1
```

## Optional tooling

* **HeidiSQL** – `./scripts/install/tooling/install-heidisql.sh`
* **LM Studio** – `./scripts/install/tooling/install-lmstudio.sh`

## Build release archive

```bash
./scripts/build.sh --exclude-docs
```

The `--exclude-docs` flag creates the release ZIP without the `docs/` directory, producing a smaller artifact that contains only the executable scripts and runtime assets.

## Notes

* The sandbox runtime is **NemoClaw**, not OpenClaw.
* Primary entry points are `bootstrap.sh` and `install.sh`; `reconfigure.sh` is an optional day‑2 helper. All are located in the repository root.
* Scripts follow the naming conventions described in `scripts/CONTEXT.md`.
