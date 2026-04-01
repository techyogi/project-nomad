#!/bin/bash
# restore-all.sh — Fully restore NOMAD on a fresh machine from a backup
#
# Usage: ./scripts/restore-all.sh
#
# Run this from the project directory after copying/cloning to a new machine.
# It will:
#   1. Update .env with the current project path
#   2. Create bind-backed Docker volumes for MySQL and Nominatim
#   3. Add nomad.local to /etc/hosts (if not already present)
#   4. Install mkcert and generate TLS certificates (if needed)
#   5. Build and start all containers
#
# Prerequisites:
#   - Docker is running
#   - Homebrew installed (for mkcert)
#   - storage/ directory exists with data

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STORAGE_PATH="$PROJECT_DIR/storage"

echo -e "${YELLOW}=== NOMAD Full Restore ===${NC}"
echo "Project: $PROJECT_DIR"
echo "Storage: $STORAGE_PATH"
echo ""

# Preflight checks
if ! command -v docker &>/dev/null; then
    echo -e "${RED}Error: Docker is not installed.${NC}"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo -e "${RED}Error: Docker is not running.${NC}"
    exit 1
fi

if [ ! -d "$STORAGE_PATH" ]; then
    echo -e "${RED}Error: storage/ directory not found. Is this a valid backup?${NC}"
    exit 1
fi

# Step 1: Update .env
echo -e "${GREEN}[1/5]${NC} Updating .env..."
cat > "$PROJECT_DIR/.env" <<EOF
NOMAD_STORAGE_PATH=$STORAGE_PATH
EOF
echo "  NOMAD_STORAGE_PATH=$STORAGE_PATH"

# Step 2: Create bind-backed Docker volumes
echo -e "${GREEN}[2/5]${NC} Creating Docker volumes..."
for vol in mysql nominatim; do
    VOLUME_NAME="project-nomad_nomad-$vol"
    DEVICE_PATH="$STORAGE_PATH/$vol"

    if [ ! -d "$DEVICE_PATH" ]; then
        echo -e "  ${YELLOW}Skipping $vol — $DEVICE_PATH does not exist${NC}"
        continue
    fi

    # Remove existing volume if it points somewhere else
    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        EXISTING_DEVICE=$(docker volume inspect "$VOLUME_NAME" --format '{{index .Options "device"}}' 2>/dev/null || echo "")
        if [ "$EXISTING_DEVICE" = "$DEVICE_PATH" ]; then
            echo "  $vol — volume already exists and points to correct path"
            continue
        else
            echo "  $vol — removing existing volume (pointed to $EXISTING_DEVICE)"
            docker volume rm "$VOLUME_NAME" 2>/dev/null || true
        fi
    fi

    docker volume create \
        --driver local \
        --opt type=none \
        --opt o=bind \
        --opt device="$DEVICE_PATH" \
        "$VOLUME_NAME" >/dev/null
    echo "  Created $VOLUME_NAME → $DEVICE_PATH"
done

# Step 3: /etc/hosts
echo -e "${GREEN}[3/5]${NC} Checking /etc/hosts..."
if grep -q "nomad.local" /etc/hosts; then
    echo "  nomad.local already in /etc/hosts"
    # Ensure IPv6 entry exists (prevents 5s DNS timeout on .local domains)
    if ! grep -q "::1.*nomad.local" /etc/hosts; then
        echo "  Adding IPv6 entry for nomad.local (requires sudo)..."
        sudo sed -i '' '/127.0.0.1  nomad.local/a\
::1  nomad.local' /etc/hosts
        echo "  Added: ::1  nomad.local"
    fi
else
    echo "  Adding nomad.local to /etc/hosts (requires sudo)..."
    sudo sh -c 'printf "127.0.0.1  nomad.local\n::1  nomad.local\n" >> /etc/hosts'
    echo "  Added: 127.0.0.1  nomad.local"
    echo "  Added: ::1  nomad.local"
fi

# Step 4: TLS certificates
echo -e "${GREEN}[4/5]${NC} Setting up TLS certificates..."
if [ -f "$PROJECT_DIR/certs/nomad.local.pem" ] && [ -f "$PROJECT_DIR/certs/nomad.local-key.pem" ]; then
    echo "  Certificates already exist"
else
    if ! command -v mkcert &>/dev/null; then
        if command -v brew &>/dev/null; then
            echo "  Installing mkcert via Homebrew..."
            brew install mkcert 2>/dev/null
        else
            echo -e "  ${RED}mkcert not found and Homebrew not available.${NC}"
            echo "  Install mkcert manually: https://github.com/FiloSottile/mkcert"
            echo "  Then run: mkcert -install && mkdir -p certs && mkcert -cert-file certs/nomad.local.pem -key-file certs/nomad.local-key.pem nomad.local localhost 127.0.0.1"
            echo "  Continuing without TLS — geolocation will only work on localhost."
        fi
    fi

    if command -v mkcert &>/dev/null; then
        mkcert -install 2>/dev/null
        mkdir -p "$PROJECT_DIR/certs"
        mkcert \
            -cert-file "$PROJECT_DIR/certs/nomad.local.pem" \
            -key-file "$PROJECT_DIR/certs/nomad.local-key.pem" \
            nomad.local localhost 127.0.0.1 2>/dev/null

        # Ensure traefik dynamic config exists
        if [ ! -f "$PROJECT_DIR/certs/traefik-dynamic.yml" ]; then
            cat > "$PROJECT_DIR/certs/traefik-dynamic.yml" <<'TRAEFIK'
tls:
  certificates:
    - certFile: /etc/traefik/certs/nomad.local.pem
      keyFile: /etc/traefik/certs/nomad.local-key.pem
TRAEFIK
        fi
        echo "  Generated TLS certificates for nomad.local"
    fi
fi

# Step 5: Build and start
echo -e "${GREEN}[5/5]${NC} Building and starting containers..."
cd "$PROJECT_DIR"
docker compose up -d --build

echo ""
echo -e "${GREEN}=== Restore complete ===${NC}"
echo ""
echo "Wait ~30 seconds for services to start, then access:"
echo "  https://nomad.local"
echo ""
echo "To start NOMAD-managed services (Ollama, Kiwix, etc.),"
echo "they should auto-start if they were installed before backup."
echo "If not, install them from the NOMAD UI."
