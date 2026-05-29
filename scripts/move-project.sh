#!/bin/bash
# move-project.sh — Run AFTER moving the project directory to a new location
#
# Usage: mv ~/source/Projects/project-nomad /new/location/
# THEN:  cd /new/path/to/project-nomad && ./scripts/move-project.sh
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
cat >"$PROJECT_DIR/.env" <<EOF
NOMAD_STORAGE_PATH=$STORAGE_PATH
EOF
echo "  NOMAD_STORAGE_PATH=$STORAGE_PATH"

# Step 2: Stop and remove containers (they hold references to old paths)
echo -e "${GREEN}[2/4]${NC} Stopping containers..."
cd "$PROJECT_DIR"
# Remove managed containers first (must be recreated with new paths)
for c in $(docker ps -aq --filter "label=com.docker.compose.project=project-nomad" 2>/dev/null); do
  # Skip core compose containers (they get recreated by docker compose up)
  NAME=$(docker inspect "$c" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
  case "$NAME" in nomad_admin|nomad_mysql|nomad_redis|nomad_traefik|nomad_dozzle) continue ;; esac
  docker rm -f "$c" 2>/dev/null || true
  echo "  Removed $NAME"
done
docker compose down 2>/dev/null || true

# Step 3: Start core containers, then update DB paths
echo -e "${GREEN}[3/4]${NC} Starting containers and updating database..."
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

# Step 5: Recreate and start managed containers from DB configs
echo -e "${GREEN}[4/4]${NC} Recreating managed containers..."
docker exec nomad_mysql mysql -u nomad_user -pnomad_local_pass nomad -sNe \
  "SELECT service_name, container_image, container_config, IFNULL(container_command,'') FROM services WHERE installed = 1;" 2>/dev/null | \
while IFS=$'\t' read -r svc_name svc_image svc_config svc_cmd; do
  # Skip if container already exists (shouldn't happen, but safety check)
  if docker ps -aq --filter "name=^${svc_name}$" 2>/dev/null | grep -q .; then
    echo "  $svc_name — already exists, skipping"
    continue
  fi

  echo -n "  $svc_name — "

  # Build docker create command via python (handles JSON parsing reliably)
  python3 -c "
import json, subprocess, sys

name = '${svc_name}'
image = '${svc_image}'
config = json.loads('''${svc_config}''')
container_cmd = '''${svc_cmd}'''.strip()

cmd = ['docker', 'create', '--name', name,
       '--label', 'com.docker.compose.project=project-nomad',
       '--network', 'project-nomad_default',
       '--restart', 'unless-stopped']

# Binds
for b in (config.get('HostConfig', {}).get('Binds') or []):
    cmd.extend(['-v', b])

# Ports
for cp, hbs in (config.get('HostConfig', {}).get('PortBindings') or {}).items():
    for hb in hbs:
        cmd.extend(['-p', f\"{hb['HostPort']}:{cp}\"])

# Env
for e in (config.get('Env') or []):
    cmd.extend(['-e', e])

# Entrypoint
ep = config.get('Entrypoint')
if ep:
    for e in ep:
        cmd.extend(['--entrypoint', e])

cmd.append(image)

# Container command (e.g. '*.zim --address=all')
if container_cmd:
    cmd.extend(container_cmd.split())

result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print(f'FAILED: {result.stderr.strip()}')
    sys.exit(1)
" 2>&1

  if [ $? -eq 0 ]; then
    docker start "$svc_name" >/dev/null 2>&1
    echo "started"
  else
    echo "failed"
  fi
done

echo ""
echo -e "${GREEN}=== Move complete ===${NC}"
echo "All containers running. Access at:"
echo "  https://nomad.local"
