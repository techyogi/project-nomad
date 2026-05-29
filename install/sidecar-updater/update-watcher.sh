#!/bin/bash

# Project N.O.M.A.D. Update Sidecar - Polls for update requests and executes them

# All settings below can be overridden via environment variables. The defaults
# match the production install (management_compose.yaml); the local dev stack
# overrides COMPOSE_FILE / VERSION_ENV_FILE / SERVICES_TO_UPDATE.
SHARED_DIR="${SHARED_DIR:-/shared}"
REQUEST_FILE="${SHARED_DIR}/update-request"
STATUS_FILE="${SHARED_DIR}/update-status"
LOG_FILE="${SHARED_DIR}/update-log"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/project-nomad/compose.yml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-project-nomad}"
# Image repo whose tag gets bumped on update (used by both the sed and env-file paths).
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/crosstalk-solutions/project-nomad}"
# Services recreated after pulling. Production updates the full core set; a
# build-from-source dev stack only needs the admin image swapped.
SERVICES_TO_UPDATE="${SERVICES_TO_UPDATE:-admin mysql redis dozzle}"
# When set, the target tag is persisted as NOMAD_VERSION in this env file and the
# image is pulled explicitly, instead of rewriting the (version-controlled) compose
# file in place. Used by dual-mode (build + image) stacks.
VERSION_ENV_FILE="${VERSION_ENV_FILE:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

write_status() {
    local stage="$1"
    local progress="$2"
    local message="$3"
    
    cat > "$STATUS_FILE" <<EOF
{
  "stage": "$stage",
  "progress": $progress,
  "message": "$message",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

perform_update() {
    local target_tag="$1"

    log "Update request received - starting system update (target tag: ${target_tag})"

    # Clear old logs
    > "$LOG_FILE"

    # Stage 1: Starting
    write_status "starting" 0 "System update initiated"
    log "System update initiated"
    sleep 1

    # Apply the target image tag before pulling.
    if [ -n "$VERSION_ENV_FILE" ]; then
        # Dual-mode stack: persist the tag as NOMAD_VERSION in the env file so the
        # compose `image:` (…:${NOMAD_VERSION:-latest}) resolves to it, without
        # mutating the version-controlled compose file.
        log "Persisting image tag '${target_tag}' as NOMAD_VERSION in ${VERSION_ENV_FILE}..."
        if touch "$VERSION_ENV_FILE" 2>> "$LOG_FILE" \
            && { grep -v '^NOMAD_VERSION=' "$VERSION_ENV_FILE" > "${VERSION_ENV_FILE}.tmp" 2>/dev/null || true; } \
            && mv "${VERSION_ENV_FILE}.tmp" "$VERSION_ENV_FILE" \
            && echo "NOMAD_VERSION=${target_tag}" >> "$VERSION_ENV_FILE"; then
            log "Pinned NOMAD_VERSION=${target_tag} in ${VERSION_ENV_FILE}"
        else
            log "ERROR: Failed to persist NOMAD_VERSION to ${VERSION_ENV_FILE}"
            write_status "error" 0 "Failed to persist target version - check logs"
            return 1
        fi

        # Stage 2: Pull the target image explicitly (the admin service is buildable,
        # so `docker compose pull` may skip it).
        write_status "pulling" 20 "Pulling ${IMAGE_REPO}:${target_tag}..."
        log "Pulling ${IMAGE_REPO}:${target_tag}..."
        if docker pull "${IMAGE_REPO}:${target_tag}" >> "$LOG_FILE" 2>&1; then
            log "Successfully pulled ${IMAGE_REPO}:${target_tag}"
            write_status "pulled" 60 "Image pulled successfully"
        else
            log "ERROR: Failed to pull ${IMAGE_REPO}:${target_tag}"
            write_status "error" 0 "Failed to pull Docker image - check logs"
            return 1
        fi
    else
        # Production path: rewrite the deployed compose file's image tag in place.
        log "Applying image tag '${target_tag}' to compose.yml..."
        if sed -i "s|\(image: ${IMAGE_REPO}\):.*|\1:${target_tag}|" "$COMPOSE_FILE" 2>> "$LOG_FILE"; then
            log "Successfully updated compose.yml admin image tag to '${target_tag}'"
        else
            log "ERROR: Failed to update compose.yml image tag"
            write_status "error" 0 "Failed to update compose.yml image tag - check logs"
            return 1
        fi

        # Stage 2: Pulling images
        write_status "pulling" 20 "Pulling latest Docker images..."
        log "Pulling latest Docker images..."

        if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" pull >> "$LOG_FILE" 2>&1; then
            log "Successfully pulled latest images"
            write_status "pulled" 60 "Images pulled successfully"
        else
            log "ERROR: Failed to pull images"
            write_status "error" 0 "Failed to pull Docker images - check logs"
            return 1
        fi
    fi
    
    sleep 2
    
    # Stage 3: Recreating containers individually (excluding updater)
    write_status "recreating" 65 "Recreating containers individually..."
    log "Recreating containers individually (excluding updater)..."

    # Services to recreate are defined by $SERVICES_TO_UPDATE (env-overridable).
    local service_count
    service_count=$(echo "$SERVICES_TO_UPDATE" | wc -w | tr -d ' ')
    [ "$service_count" -gt 0 ] || service_count=1

    local current_progress=65
    local progress_per_service=$(( (95 - 65) / service_count ))  # spread 65→95% across services
    [ "$progress_per_service" -gt 0 ] || progress_per_service=1
    
    for service in $SERVICES_TO_UPDATE; do
        log "Updating service: $service"
        write_status "recreating" $current_progress "Recreating $service..."
        
        # Stop the service
        log "  Stopping $service..."
        docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" stop "$service" >> "$LOG_FILE" 2>&1 || log "  WARNING: Failed to stop $service"
        
        # Remove the container
        log "  Removing old $service container..."
        docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" rm -f "$service" >> "$LOG_FILE" 2>&1 || log "  WARNING: Failed to remove $service"
        
        # Recreate and start with new image. --no-build forces use of the pulled
        # image even when the service also declares a build context (dual-mode).
        log "  Starting new $service container..."
        if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" up -d --no-deps --no-build "$service" >> "$LOG_FILE" 2>&1; then
            log "  ✓ Successfully recreated $service"
        else
            log "  ERROR: Failed to recreate $service"
            write_status "error" $current_progress "Failed to recreate $service - check logs"
            return 1
        fi
        
        current_progress=$((current_progress + progress_per_service))
    done
    
    log "Successfully recreated all containers"
    write_status "complete" 100 "System update completed successfully"
    log "System update completed successfully"
    
    return 0
}

cleanup() {
    log "Update sidecar shutting down"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main watch loop
log "Update sidecar started - watching for update requests"
write_status "idle" 0 "Ready for update requests"

while true; do
    # Check if an update request file exists
    if [ -f "$REQUEST_FILE" ]; then
        log "Found update request file"
        
        # Read request details
        REQUEST_DATA=$(cat "$REQUEST_FILE" 2>/dev/null || echo "{}")
        log "Request data: $REQUEST_DATA"

        # Extract target tag from request (defaults to "latest" if not provided)
        TARGET_TAG=$(echo "$REQUEST_DATA" | jq -r '.target_tag // "latest"')
        log "Target image tag: ${TARGET_TAG}"

        # Remove the request file to prevent re-processing
        rm -f "$REQUEST_FILE"

        if perform_update "$TARGET_TAG"; then
            log "Update completed successfully"
        else
            log "Update failed - see logs for details"
        fi
        
        sleep 5
        write_status "idle" 0 "Ready for update requests"
    fi
    
    # Sleep before next check (1 second polling)
    sleep 1
done
