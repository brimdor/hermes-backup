# Command-Central Disaster Recovery Guide

> **Purpose**: Step-by-step procedure to rebuild command-central from a bare-metal wipe using the GitHub backup.

> **Repository**: `brimdor/hermes-backup` (public) — `master` branch holds the latest backup snapshot.

> **Last updated**: 2026-05-20

---

## Prerequisites — What You Need Before Starting

### Credentials and accounts (have these ready)

| Item | Where to get it | Notes |
|------|-----------------|-------|
| GitHub account access (brimdor) | github.com | To pull the backup repo |
| `gh` CLI OAuth token | `gh auth login` on the new machine | Needed for backup script to push on future runs |
| Ollama.com API key | ollama.com/settings | Max plan, $100/mo — all agents use this |
| Telegram bot tokens (per agent) | @BotFather on Telegram | One per active agent: Aria, Boriqua, Neo, Nia, Nova |
| Telegram allowed user IDs | Already in `.env` files inside backup | Chris=8226887535 |
| Discord bot tokens (per agent) | Discord Developer Portal | For agents using Discord |
| Discord allowed user IDs | Already in backup | Chris=136263979046666240, Kaleb=1494698611202719784 |
| Gatekeeper MCP API keys | Already in backup config.yaml | Boriqua/Nia/Nova use Gatekeeper on Luigi |
| Twingate service key | eaglepass.twingate.com admin | For Hospital-to-homelab connectivity |
| SSH keys for Hospital access | Stored on Hospital at `~/.ssh/command_central` | doctor and hermes user keys |

### System requirements

| Requirement | Spec |
|-------------|------|
| OS | CachyOS (Arch-based) — any Arch Linux variant works |
| RAM | 16GB+ (15GB is current) |
| Disk | 50GB+ free (931GB NVMe currently) |
| Network | Homelab LAN access (10.0.30.x) or Twingate |
| GPU | Optional — Radeon 890M iGPU for local Ollama inference |

### Software to install before restoring

```bash
# Arch/CachyOS base packages
sudo pacman -S --needed git python nodejs npm uv base-devel

# Install Ollama (for local + cloud model inference)
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama

# Install gh CLI (for GitHub auth — needed by backup script)
sudo pacman -S github-cli
```

---

## Phase 1: Create Users and Directory Structure

### 1.1 Create the `hermes` user

The `hermes` user is the runtime account. Its home directory is `/home/echo/` (historical naming — the home path stayed when the user was renamed from `echo` to `hermes`).

```bash
sudo useradd -m -d /home/echo -s /bin/bash -U hermes
# Add to required groups
sudo usermod -aG sys,network,wheel,audio,lp,storage,video,users,rfkill hermes
```

**Verify**: `id hermes` should show `uid=1000(hermes) gid=1000(hermes)`

### 1.2 Create the `doctor` user

The `doctor` user is the sysadmin account with full sudo.

```bash
sudo useradd -m -s /bin/bash -U doctor
sudo usermod -aG sys,network,wheel,audio,lp,storage,video,rfkill,hermes doctor
# Set up passwordless sudo
echo "doctor ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/doctor
```

**Verify**: `id doctor` should show `uid=1002(doctor) gid=1004(doctor)`

### 1.3 Enable login linger for hermes

`systemctl --user` only works when a user session exists. Linger keeps it alive at boot.

```bash
sudo loginctl enable-linger hermes
```

**Verify**: `loginctl show-user hermes | grep Linger` → `Linger=yes`

### 1.4 Create required directories

```bash
sudo mkdir -p /home/echo/backup/scripts /home/echo/backup/logs /home/echo/backup/hermes-archives
sudo mkdir -p /home/echo/archived_agents
sudo chown -R hermes:hermes /home/echo/
```

---

## Phase 2: Install Hermes Agent

Hermes is installed by cloning the git repo and setting up a Python venv with `uv`.

### 2.1 Clone the Hermes agent repo

```bash
sudo -u hermes -H git clone https://github.com/nousresearch/hermes-agent.git /home/echo/.hermes/hermes-agent
```

### 2.2 Run Hermes setup

```bash
sudo -u hermes -H bash -c 'cd /home/echo/.hermes/hermes-agent && uv venv venv --python 3.11 && source venv/bin/activate && pip install -e .'
```

**Verify**: `hermes --version` should return a version string.

### 2.3 Set up the hermes CLI wrapper

The `hermes` CLI at `/usr/local/bin/hermes` is a wrapper that runs as the hermes user:

```bash
sudo tee /usr/local/bin/hermes << 'EOF'
#!/bin/bash
set -euo pipefail
exec sudo -u hermes -H env HOME=/home/echo XDG_RUNTIME_DIR=/run/user/1000 HERMES_HOME="${HERMES_HOME:-/home/echo/.hermes}" /home/echo/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main "$@"
EOF
sudo chmod +x /usr/local/bin/hermes
sudo chown hermes:hermes /usr/local/bin/hermes
```

### 2.4 Authenticate with GitHub (for backup pushes)

```bash
sudo -u hermes gh auth login
# Follow prompts: GitHub.com, HTTPS, authenticate in browser
# Verify:
sudo -u hermes gh auth status
```

---

## Phase 3: Restore Data from Backup

### 3.1 Download and reassemble the backup

```bash
cd /tmp
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/brimdor/hermes-backup.git
cd hermes-backup

# Read the manifest to get exact filenames and SHA256
cat hermes_backup_*.manifest

# Reassemble the archive
cat hermes_backup_*.tar.gz.part* > hermes_backup.tar.gz

# Verify integrity (MUST pass before proceeding)
sha256sum -c hermes_backup_*.sha256
```

**If SHA256 verification fails, DO NOT proceed.** The backup is corrupted. Check if there's a different backup in the repo history, or use the local archive at `/home/echo/backup/hermes-archives/` if one exists.

### 3.2 Extract the archive

```bash
# Extract into the hermes home directory
tar -xzf hermes_backup.tar.gz -C /home/echo/
```

This restores:
- `.hermes/` — all agent profiles, configs, skills, memories, cron, auth, kanban
- `.mempalace/` — ChromaDB vectors, knowledge graph, config, diary, tunnels

### 3.3 Fix ownership (critical)

The archive was created as the `hermes` user, but if you extracted as root, ownership may be wrong:

```bash
sudo chown -R hermes:hermes /home/echo/.hermes /home/echo/.mempalace
sudo chmod 600 /home/echo/.hermes/auth.json
sudo chmod 700 /home/echo/.hermes /home/echo/.mempalace
```

**Verify**: `sudo find /home/echo/.hermes /home/echo/.mempalace -user root | wc -l` → should be `0`

---

## Phase 4: Rebuild Dependencies

### 4.1 Rebuild the MemPalace Python venv

MemPalace has its own venv separate from Hermes. The backup excludes the venv directory.

```bash
sudo -u hermes -H bash -c '
  python3 -m venv /home/echo/.hermes/mempalace-venv
  source /home/echo/.hermes/mempalace-venv/bin/activate
  pip install mempalace chromadb huggingface_hub tokenizers numpy
'
```

**Verify**: `sudo -u hermes /home/echo/.hermes/mempalace-venv/bin/pip show mempalace chromadb | grep -E "Name|Version"`

### 4.2 Recreate helper scripts

Several system scripts live outside the backup. Recreate them:

**`/home/echo/bin/mempalace_warmup.sh`** — periodically warms the MemPalace MCP cache:
```bash
# This script is in the backup at /home/echo/bin/mempalace_warmup.sh
# If missing, it can be recreated from the command-central-reference skill
# It runs: python -m mempalace.mcp_server via JSON-RPC initialize + status call
```

**`/home/echo/bin/mempalace_healthcheck.py`** — health check + self-heal:
```bash
# This script is in the backup if it's under /home/echo/.hermes/scripts/ or /home/echo/bin/
# If missing, check the command-central-reference skill for the template
```

**`/usr/local/bin/hermes-pre-backup-fix`** — fixes root-owned files before backup:
```bash
sudo tee /usr/local/bin/hermes-pre-backup-fix << 'FIX'
#!/bin/bash
find /home/echo/.hermes -user root -type f -exec chown hermes:hermes {} \; 2>/dev/null
find /home/echo/.mempalace -user root -type f -exec chown hermes:hermes {} \; 2>/dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] hermes-pre-backup-fix: permissions fixed" >> /home/echo/backup/logs/backup.log
FIX
sudo chmod +x /usr/local/bin/hermes-pre-backup-fix
```

### 4.3 Set up `.gitconfig` for the hermes user

```bash
sudo -u hermes tee /home/echo/.gitconfig << 'GITCONFIG'
# Minimal gitconfig — backup uses HTTPS with gh credential helper
[credential "https://github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
[user]
	email = hermes-backup@command-central.local
	name = Hermes Backup Bot
[credential]
	helper = store
[credential "Store"]
	path = /home/echo/.config/git/credentials
GITCONFIG
```

**Do NOT add** `[filter "lfs"]` or `[url "https://github.com/"] insteadOf = git@github.com:` — both break the backup script.

### 4.4 Recreate SSH keys (if needed)

The backup includes `/home/echo/.ssh/` keys. If they were lost:

```bash
sudo -u hermes ssh-keygen -t ed25519 -f /home/echo/.ssh/id_ed25519 -N ""
# Add the public key to any servers that need it
sudo -u hermes cat /home/echo/.ssh/id_ed25519.pub
```

---

## Phase 5: Set Up Systemd Services

All agent gateways and supporting services run as `hermes` user systemd units.

### 5.1 Create gateway service units (one per agent)

For each active agent (aria, boriqua, neo, nia, nova):

```bash
sudo -u hermes mkdir -p /home/echo/.config/systemd/user/

for agent in aria boriqua neo nia nova; do
sudo -u hermes tee /home/echo/.config/systemd/user/hermes-gateway-${agent}.service << EOF
[Unit]
Description=Hermes Agent Gateway - ${agent}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/home/echo/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main --profile ${agent} gateway run --replace
WorkingDirectory=/home/echo/.hermes/hermes-agent
Environment="PATH=/home/echo/.hermes/hermes-agent/venv/bin:/home/echo/.hermes/hermes-agent/node_modules/.bin:/usr/bin:/home/echo/.local/bin:/home/echo/.cargo/bin:/home/echo/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=/home/echo/.hermes/hermes-agent/venv"
Environment="HERMES_HOME=/home/echo/.hermes/profiles/${agent}"
Restart=always
RestartSec=5
RestartMaxDelaySec=300
RestartSteps=5
RestartForceExitStatus=75
KillMode=mixed
KillSignal=SIGTERM
ExecReload=/bin/kill -USR1 \$MAINPID
TimeoutStopSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
done
```

### 5.2 Create MemPalace warmup services (per agent)

```bash
for agent in aria boriqua neo nia nova; do
sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-warmup-${agent}.service << EOF
[Unit]
Description=Warm MemPalace for ${agent}
After=hermes-gateway-${agent}.service

[Service]
Type=oneshot
ExecStart=/home/echo/bin/mempalace_warmup.sh ${agent}
EOF

sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-warmup-${agent}.timer << EOF
[Unit]
Description=Periodic MemPalace warm-up for ${agent}

[Timer]
OnBootSec=6min
OnUnitActiveSec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF
done
```

### 5.3 Create MemPalace mining service

```bash
sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-mine.service << 'EOF'
[Unit]
Description=MemPalace mining service
After=network.target

[Service]
Type=oneshot
ExecStart=/home/echo/.hermes/mempalace-venv/bin/python -m mempalace mine /home/echo/.hermes/sessions/ --mode convos --extract general
Environment=HOME=/home/echo
WorkingDirectory=/home/echo/.hermes/hermes-agent

[Install]
WantedBy=default.target
EOF

sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-mine.timer << 'EOF'
[Unit]
Description=MemPalace mining timer - runs daily at 3 AM

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

### 5.4 Create MemPalace healthcheck service

```bash
sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-healthcheck.service << 'EOF'
[Unit]
Description=MemPalace health check and self-heal

[Service]
Type=oneshot
ExecStart=/home/echo/bin/mempalace_healthcheck.py
Environment="CHROMA_API_IMPL=chromadb.api.segment.SegmentAPI"
Environment="MEMPALACE_PALACE_PATH=/home/echo/.mempalace/palace"
Environment="MEMPAL_PALACE_PATH=/home/echo/.mempalace/palace"

[Install]
WantedBy=default.target
EOF

sudo -u hermes tee /home/echo/.config/systemd/user/mempalace-healthcheck.timer << 'EOF'
[Unit]
Description=MemPalace health check timer

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

### 5.5 Create backup service and timer

```bash
sudo -u hermes tee /home/echo/.config/systemd/user/hermes-backup.service << 'EOF'
[Unit]
Description=Hermes Backup to GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/backup/scripts/backup-hermes.sh
StandardOutput=append:%h/backup/logs/backup.log
StandardError=append:%h/backup/logs/backup.log
EOF

sudo -u hermes tee /home/echo/.config/systemd/user/hermes-backup.timer << 'EOF'
[Unit]
Description=Daily Hermes Backup Timer
After=network-online.target

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF
```

### 5.6 Create pre-backup system timer (runs as root)

```bash
sudo tee /etc/systemd/system/hermes-pre-backup-fix.service << 'EOF'
[Unit]
Description=Fix root-owned files before Hermes backup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hermes-pre-backup-fix
EOF

sudo tee /etc/systemd/system/hermes-pre-backup-fix.timer << 'EOF'
[Unit]
Description=Fix root-owned files before Hermes backup (runs at 01:55)

[Timer]
OnCalendar=*-*-* 01:55:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-pre-backup-fix.timer
```

### 5.7 Create Hermes auto-update service

```bash
sudo -u hermes tee /home/echo/.config/systemd/user/hermes-auto-update.service << 'EOF'
[Unit]
Description=Hermes safe auto-update
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/home/echo/.hermes/hermes-agent
Environment=HOME=/home/echo
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/home/echo/.hermes/scripts/hermes-auto-update-safe.sh
TimeoutStartSec=1800

[Install]
WantedBy=default.target
EOF
```

The auto-update script (`hermes-auto-update-safe.sh`) is included in the backup data at `/home/echo/.hermes/scripts/`.

### 5.8 Reload and enable all services

```bash
# Reload hermes user systemd
sudo -u hermes bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; systemctl --user daemon-reload'

# Enable and start gateway services (one at a time, 5s apart)
for agent in aria boriqua neo nia nova; do
  sudo -u hermes bash -c "export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; systemctl --user enable --now hermes-gateway-${agent}.service"
  sleep 5
done

# Enable timers
sudo -u hermes bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; systemctl --user enable --now hermes-backup.timer mempalace-mine.timer mempalace-healthcheck.timer'
for agent in aria boriqua neo nia nova; do
  sudo -u hermes bash -c "export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; systemctl --user enable --now mempalace-warmup-${agent}.timer"
done
```

---

## Phase 6: Verify the Restore

### 6.1 Check gateway services

```bash
sudo -u hermes bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; systemctl --user list-units --type=service --state=running | grep hermes-gateway'
```

Expected: 5 running services (aria, boriqua, neo, nia, nova).

### 6.2 Check MemPalace connectivity

```bash
sudo -u hermes /home/echo/.hermes/mempalace-venv/bin/mempalace --palace /home/echo/.mempalace/palace status
```

### 6.3 Check backup works

```bash
sudo /usr/local/bin/hermes-pre-backup-fix  # fix any root-owned files first
sudo -u hermes bash /home/echo/backup/scripts/backup-hermes.sh
```

Expected: "SUCCESS: Backup pushed to GitHub." at the end.

### 6.4 Check Hermes version

```bash
hermes --version
```

### 6.5 Smoke-test an agent

```bash
hermes --profile nova -z 'Reply with exactly: nova-restore-ok'
```

---

## What the Backup Does NOT Cover

These items require manual re-setup after a wipe:

| Item | Why not in backup | How to recover |
|------|-------------------|-----------------|
| `hermes-agent/` runtime | Installable from `git clone` | `git clone https://github.com/nousresearch/hermes-agent.git` |
| `mempalace-venv/` | Python venv — rebuilds from pip | `python3 -m venv && pip install mempalace chromadb` |
| `sessions/` | Ephemeral conversation data | Lost — agents start fresh |
| `state.db` (595MB) | Conversation state — rebuilds on restart | Agents recreate automatically |
| `workspace/` (2GB) | Working directory | Recreate as needed |
| `logs/`, `cache/` | Diagnostic/temporary | Rebuild on use |
| `audio_cache/`, `image_cache/` | Media files | Regenerated on use |
| SSH host keys | Machine-specific | `ssh-keygen -A` to regenerate |
| System-level configs (nftables, UFW) | Machine-specific | Reconfigure as needed |
| Citadel (web dashboard) | Not in `.hermes/` or `.mempalace/` | Separate deployment — see Citadel skill |
| Twingate config | Service account key is sensitive | Reconfigure from eaglepass admin |
| Ollama service | System package | `curl -fsSL https://ollama.com/install.sh \| sh` |
| `/home/echo/archived_agents/` | 12GB of terminated agent archives | Not backed up — low priority |

---

## Troubleshooting

### "Permission denied" errors on restore

The most common issue. Run:
```bash
sudo chown -R hermes:hermes /home/echo/.hermes /home/echo/.mempalace
sudo chmod 700 /home/echo/.hermes /home/echo/.mempalace
sudo chmod 600 /home/echo/.hermes/auth.json /home/echo/.hermes/profiles/*/.env
```

### Gateways fail to start

Check the profile `.env` files — API keys must be valid. The backup includes the key values but if Ollama keys were rotated, update `OLLAMA_API_KEY_*` in each profile's `.env`.

```bash
hermes --profile nova config check  # validate config
sudo tail -20 /home/echo/.hermes/profiles/nova/logs/errors.log  # check errors
```

### MemPalace MCP fails to connect

The MemPalace venv must be rebuilt with compatible ChromaDB version:
```bash
sudo -u hermes /home/echo/.hermes/mempalace-venv/bin/pip install 'chromadb>=1.5.0' 'mempalace>=3.2.0'
```

If ChromaDB version doesn't match the DB format, you'll see `KeyError: '_type'`. The fix is upgrading ChromaDB in the venv (not rebuilding the DB).

### Backup script fails on clone

The backup script uses HTTPS to GitHub. If `gh auth` isn't set up, the clone will fail:
```bash
sudo -u hermes gh auth login
# Then verify:
sudo -u hermes gh auth status
```

### `systemctl --user` doesn't work from doctor account

You need the hermes user's DBUS session:
```bash
sudo -u hermes XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user <command>
```

Or use the `hermes` CLI wrapper which handles this automatically.