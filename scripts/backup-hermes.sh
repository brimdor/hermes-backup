#!/bin/bash
#==============================================================================
# Hermes Environment Backup Script
# Backs up ~/.hermes and ~/.mempalace to GitHub repo: brimdor/hermes-backup
#==============================================================================

set -euo pipefail

# Configuration
REPO_NAME="hermes-backup"
BACKUP_USER="brimdor"
REMOTE_REPO="${BACKUP_USER}/${REPO_NAME}"
BACKUP_DIR="$HOME/backup/hermes-backup-temp"
SOURCE_HERMES="$HOME/.hermes"
SOURCE_MEMPALACE="$HOME/.mempalace"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="hermes_backup_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/${BACKUP_FILENAME}"
LOG_FILE="$HOME/backup/logs/backup.log"

# Ensure log directory exists
mkdir -p "$HOME/backup/logs"

# Logging function
log() {
    echo "[$(date +%Y-%m-%d %H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Hermes Backup Starting"
log "=========================================="

# Check for uncommitted changes in backup repo
if [ -d "$BACKUP_DIR/.git" ]; then
    cd "$BACKUP_DIR"
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        log "WARNING: Uncommitted changes exist in backup repo"
        log "Stashing before pull..."
        git stash push -m "pre-backup stash $(date)" 2>/dev/null || true
    fi
fi

# Clean up any previous temp directory
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Create the backup archive
log "Creating backup archive..."

# Build exclusion patterns for tar
EXCLUDE_PATTERNS=(
    --exclude="hermes-agent"
    --exclude="__pycache__"
    --exclude="*.pyc"
    --exclude="logs"
    --exclude="cache"
    --exclude="audio_cache"
    --exclude="image_cache"
    --exclude="browser_recordings"
    --exclude="mempalace-venv"
    --exclude="*.ogg"
    --exclude="*.mp3"
    --exclude="*.log"
    --exclude="sessions/*.json"
    --exclude="heartbeat"
    --exclude="checkpoints"
    --exclude="sandboxes"
    --exclude="backups"
    --exclude="doc-overhaul-backups"
    --exclude="model-lock-backups"
    --exclude="provider-prune-backups"
    --exclude="*.sqlite3-shm"
    --exclude="*.sqlite3-wal"
)

# Create tar archive excluding large/transient files
tar -czf "$ARCHIVE_PATH" \
    -C "$HOME" \
    "${EXCLUDE_PATTERNS[@]}" \
    .hermes .mempalace 2>&1 | tee -a "$LOG_FILE"

ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
log "Backup archive created: ${BACKUP_FILENAME} (${ARCHIVE_SIZE})"

# Clone or update the backup repo
if [ -d "$BACKUP_DIR/.git" ]; then
    log "Updating existing backup repo..."
    cd "$BACKUP_DIR"
    git pull origin main --quiet 2>&1 | tee -a "$LOG_FILE" || {
        log "Pull failed, re-cloning..."
        rm -rf "$BACKUP_DIR"
        git clone "git@github.com:${REMOTE_REPO}.git" "$BACKUP_DIR" --quiet
        cd "$BACKUP_DIR"
    }
else
    log "Cloning backup repo..."
    git clone "git@github.com:${REMOTE_REPO}.git" "$BACKUP_DIR" --quiet
    cd "$BACKUP_DIR"
fi

# Remove old backups (keep last 7)
cd "$BACKUP_DIR"
ls -t hermes_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f 2>/dev/null || true

# Move new archive to repo
mv "$ARCHIVE_PATH" "$BACKUP_DIR/"

# Add and commit
cd "$BACKUP_DIR"
git add "$BACKUP_FILENAME"
git commit -m "Backup $(date +%Y-%m-%d %H:%M)" 2>&1 | tee -a "$LOG_FILE"

# Push to GitHub
log "Pushing to GitHub..."
if git push origin main 2>&1 | tee -a "$LOG_FILE"; then
    log "SUCCESS: Backup pushed to github.com:${REMOTE_REPO}"
else
    log "ERROR: Failed to push backup"
    exit 1
fi

# Cleanup
rm -rf "$BACKUP_DIR"
log "Backup complete!"
log "=========================================="
