#!/bin/bash
# move-project.sh — Run AFTER moving the project directory to a new location
#
# Usage: cd /new/path/to/project-nomad && ./scripts/move-project.sh
#
# This updates all references to the old path without rebuilding or re-importing.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STORAGE_PATH="$PROJECT_DIR/storage"

# Read old path from .env
OLD_STORAGE_PATH=""
if [ -f "$PROJECT_DIR/.env" ]; then
    OLD_STORAGE_PATH=$(grep '^NOMAD_STORAGE_PATH=' "$PROJECT_DIR/.env" | cut -d= -f2)
fi

if [ -z "$OLD_STORAGE_PATH" ]; then
    echo -e "${RED}Error: Could not read old NOMAD_STORAGE_PATH from .env${NC}"
    exit 1
fi

OLD_PROJECT_DIR=$(dirname "$OLD_STORAGE_PATH")

if [ "$OLD_PROJECT_DIR" = "$PROJECT_DIR" ]; then
    echo -e "${GREEN}Paths haven't changed. Nothing to do.${NC}"
    exit 0
fi

echo -e "${YELLOW}=== NOMAD Move ===${NC}"
echo "Old: $OLD_PROJECT_DIR"
echo "New: $PROJECT_DIR"
echo ""

# Step 1: Update .env
echo -e "${GREEN}[1/4]${NC} Updating .env..."
cat > "$PROJECT_DIR/.env" <<EOF
NOMAD_STORAGE_PATH=$STORAGE_PATH
EOF
echo "  NOMAD_STORAGE_PATH=$STORAGE_PATH"

# Step 2: Stop containers (they hold references to old paths)
echo -e "${GREEN}[2/4]${NC} Stopping containers..."
cd "$PROJECT_DIR"
docker compose down 2>/dev/null || true
# Also stop managed containers
for c in $(docker ps -aq --filter "label=com.docker.compose.project=project-nomad" 2>/dev/null); do
    docker stop "$c" 2>/dev/null || true
done

# Step 3: Recreate bind-backed volumes
echo -e "${GREEN}[3/4]${NC} Recreating Docker volumes..."
for vol in mysql nominatim; do
    VOLUME_NAME="project-nomad_nomad-$vol"
    DEVICE_PATH="$STORAGE_PATH/$vol"

    if [ ! -d "$DEVICE_PATH" ]; then
        echo -e "  ${YELLOW}Skipping $vol — $DEVICE_PATH does not exist${NC}"
        continue
    fi

    docker volume rm "$VOLUME_NAME" 2>/dev/null || true
    docker volume create \
        --driver local \
        --opt type=none \
        --opt o=bind \
        --opt device="$DEVICE_PATH" \
        "$VOLUME_NAME" >/dev/null
    echo "  $VOLUME_NAME → $DEVICE_PATH"
done

# Step 4: Start core containers, then update DB paths
echo -e "${GREEN}[4/4]${NC} Starting containers and updating database..."
docker compose up -d --build

# Wait for MySQL
echo "  Waiting for MySQL..."
for i in $(seq 1 30); do
    if docker exec nomad_mysql mysqladmin ping -u nomad_user -pnomad_local_pass &>/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Rewrite paths in managed container configs
docker exec nomad_mysql mysql -u nomad_user -pnomad_local_pass nomad -e \
    "UPDATE services SET container_config = REPLACE(container_config, '${OLD_PROJECT_DIR}/', '${PROJECT_DIR}/') WHERE container_config LIKE '%${OLD_PROJECT_DIR}%';" 2>/dev/null
echo "  Updated managed container bind paths"

echo ""
echo -e "${GREEN}=== Move complete ===${NC}"
echo "  https://nomad.local"
