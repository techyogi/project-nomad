#!/bin/bash
# backup-all.sh — Complete NOMAD backup: code, config, and all data
#
# Usage: ./scripts/backup-all.sh <destination>
#   Example: ./scripts/backup-all.sh /Volumes/MySSD/nomad-backup
#
# Includes everything needed to restore on a fresh machine:
#   - Full project directory (code, docker-compose, scripts)
#   - storage/ (all data — ZIM files, maps, models, databases)
#   - .env configuration
#
# Does NOT include (machine-specific, regenerated on restore):
#   - certs/ (TLS certs — regenerated per machine)
#   - node_modules/

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <destination>"
    echo "Example: $0 /Volumes/MySSD/nomad-backup"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEST="$1"

echo "=== NOMAD Full Backup ==="
echo "Source: $PROJECT_DIR"
echo "Dest:   $DEST"
echo ""
echo "Data size:"
du -sh "$PROJECT_DIR/storage/" 2>/dev/null || echo "  No storage directory"
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

mkdir -p "$DEST"

rsync -a --info=progress2 \
    --exclude 'certs/' \
    --exclude 'node_modules/' \
    --exclude 'admin/node_modules/' \
    --exclude 'admin/build/' \
    --exclude '.git/' \
    "$PROJECT_DIR/" "$DEST/"

echo ""
echo "=== Backup complete ==="
echo "Total: $(du -sh "$DEST" | cut -f1)"
echo ""
echo "To restore on a new machine:"
echo "  cd $DEST"
echo "  ./scripts/restore-all.sh"
