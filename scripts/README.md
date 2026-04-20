# Hermes Backup

Automated backup of the Hermes AI agent environment running on command-central.

## What gets backed up

- `~/.hermes/` - Hermes configuration, agent profiles, skills, memories, workspace
- `~/.mempalace/` - Knowledge graph and memory palace data

## Excluded from backup

These are regenerated at runtime or too large:
- Hermes platform source (`hermes-agent/`) - restored via `hermes update`
- Logs, caches, browser recordings
- Audio/image caches
- Session snapshots
- Python virtual environments

## Backup schedule

- **Daily**: Automatic via cron at 02:00 AM
- **On-demand**: Run `./scripts/backup-hermes.sh` manually

## Manual restore

```bash
# Download latest backup
cd ~/backup
git clone git@github.com:brimdor/hermes-backup.git
cd hermes-backup

# Find latest backup
LATEST=$(ls -t hermes_backup_*.tar.gz | head -1)

# Restore to home directory
tar -xzf "$LATEST" -C ~/

# Restart Hermes gateway
systemctl --user restart hermes-gateway
```

## Backup location

Repo: https://github.com/brimdor/hermes-backup

Backups are stored as dated tarballs:
- `hermes_backup_YYYYMMDD_HHMMSS.tar.gz`

Last 7 backups are retained locally in the repo.
