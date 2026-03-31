#!/bin/bash
# sync-upstream.sh — Pull upstream changes and rebase local feature branch
#
# Usage: ./scripts/sync-upstream.sh
#
# This script:
# 1. Fetches latest from upstream (origin/main)
# 2. Updates local main
# 3. Rebases feature/map-geolocation-search (Nominatim + local customizations) onto main
# 4. Rebuilds the Docker container if rebase succeeded
#
# Safe to run anytime. Will abort on conflicts and let you resolve manually.

set -euo pipefail

FEATURE_BRANCH="feature/map-geolocation-search"
MAIN_BRANCH="main"
REMOTE="origin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== NOMAD Upstream Sync ===${NC}"
echo ""

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${RED}Error: You have uncommitted changes. Commit or stash them first.${NC}"
    echo ""
    git status --short
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)

# Step 1: Update main
echo -e "${GREEN}[1/4]${NC} Fetching latest from ${REMOTE}..."
git fetch "$REMOTE"

echo -e "${GREEN}[2/4]${NC} Updating local ${MAIN_BRANCH}..."
git checkout "$MAIN_BRANCH"
git pull "$REMOTE" "$MAIN_BRANCH"

UPSTREAM_HEAD=$(git rev-parse HEAD)
echo "  Main is now at: $(git log --oneline -1)"

# Step 3: Rebase feature branch
echo -e "${GREEN}[3/4]${NC} Rebasing ${FEATURE_BRANCH} onto ${MAIN_BRANCH}..."
git checkout "$FEATURE_BRANCH"

FEATURE_HEAD_BEFORE=$(git rev-parse HEAD)

if git rebase "$MAIN_BRANCH"; then
    FEATURE_HEAD_AFTER=$(git rev-parse HEAD)
    if [ "$FEATURE_HEAD_BEFORE" = "$FEATURE_HEAD_AFTER" ]; then
        echo "  Already up to date — no changes to rebase."
    else
        echo "  Rebase complete. Feature branch updated."
    fi
else
    echo ""
    echo -e "${RED}Rebase failed due to conflicts.${NC}"
    echo ""
    echo "To resolve:"
    echo "  1. Fix conflicts in the listed files"
    echo "  2. git add <fixed files>"
    echo "  3. git rebase --continue"
    echo ""
    echo "Or to abort: git rebase --abort"
    exit 1
fi

# Step 4: Rebuild
echo ""
echo -e "${GREEN}[4/4]${NC} Rebuilding Docker containers..."
echo ""
read -p "Rebuild now? This will restart the admin container. [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose up -d --build
    echo ""
    echo -e "${GREEN}Done!${NC} Containers rebuilding. Wait ~30s then access https://nomad.local"
else
    echo ""
    echo "Skipped rebuild. Run 'docker compose up -d --build' when ready."
fi

echo ""
echo -e "${GREEN}=== Sync complete ===${NC}"
echo ""
echo "Summary:"
echo "  Main:    $(git log --oneline $MAIN_BRANCH -1)"
echo "  Feature: $(git log --oneline $FEATURE_BRANCH -1)"
echo ""
echo "Local-only features preserved:"
echo "  - Nominatim offline geocoding (TIGER addresses)"
echo "  - Traefik TLS (https://nomad.local)"
echo "  - Download cancel button"
echo "  - Nominatim search integration"

# Return to feature branch
git checkout "$FEATURE_BRANCH" 2>/dev/null
