# Project N.O.M.A.D. — Local Development Setup

This documents the local customizations on top of upstream NOMAD.
These run on `feature/map-geolocation-search` branch and are NOT in upstream.

## Quick Start

```bash
# Start everything
docker compose up -d --build

# Access
https://nomad.local        # Main UI (Traefik TLS)
http://nomad.local:9999    # Dozzle log viewer
http://nomad.local:8400    # Nominatim direct (debug)
```

## Prerequisites

- Docker Desktop or OrbStack
- mkcert (`brew install mkcert && mkcert -install`)
- /etc/hosts entry: `127.0.0.1 nomad.local`

## Architecture

```
Browser (HTTPS) → Traefik (:443) → Admin (:8080) → MySQL/Redis
                                  → Nominatim (:8080, exposed :8400)
                                  → Ollama, Qdrant, Kiwix (managed via Docker socket)
```

## Local-Only Features

### 1. Traefik TLS Proxy
- Self-signed certs via mkcert in `./certs/`
- HTTPS required for browser geolocation API
- HTTP → HTTPS redirect on port 80
- Config: `docker-compose.yml` + `certs/traefik-dynamic.yml`

### 2. Nominatim Offline Geocoding
- Image: `mediagis/nominatim:4.4`
- Data: US Northeast OSM extract + TIGER addresses + US postcodes
- Import style: `full` (includes house numbers where OSM has them)
- TIGER fills gaps for US street-level addressing
- Data persists in Docker volume: `nomad-nominatim-data`
- Container name: `nomad_nominatim`, internal port 8080, host port 8400
- API: `/api/nominatim/search?q=...`, `/api/nominatim/reverse?lat=...&lon=...`

### 3. Map Enhancements
- Geolocation button (requires HTTPS)
- Search bar: Nominatim first, viewport features fallback
- Red marker + fly-to on result selection
- X-Forwarded-Proto fix for reverse proxy HTTPS

### 4. Download Cancel Button
- X button on active downloads to cancel in-progress jobs
- Handles BullMQ lock contention gracefully
- Resets Wikipedia selection status on cancel

## Files Modified (vs upstream main)

```
# New files
admin/app/controllers/nominatim_controller.ts
admin/app/services/nominatim_service.ts
admin/inertia/components/maps/MapSearchControl.tsx
docker-compose.yml
certs/traefik-dynamic.yml
scripts/sync-upstream.sh
LOCAL_SETUP.md

# Modified files
admin/constants/service_names.ts          — added NOMINATIM
admin/database/seeders/service_seeder.ts  — added Nominatim service definition
admin/start/routes.ts                     — added /api/nominatim/* routes
admin/inertia/lib/api.ts                  — added nominatimSearch/Status, comma strip
admin/inertia/components/maps/MapComponent.tsx — geolocation, search, Nominatim
admin/inertia/components/maps/MapSearchControl.tsx — search UI
admin/app/controllers/maps_controller.ts  — X-Forwarded-Proto fix
admin/app/controllers/downloads_controller.ts — error handling
admin/app/services/download_service.ts    — cancel + dismiss + Wikipedia reset
admin/inertia/components/ActiveDownloads.tsx — cancel button UI
.gitignore                                — storage/, certs/
```

## Upstream Sync

Run when upstream releases updates:

```bash
./scripts/sync-upstream.sh
```

This fetches main, rebases the feature branch, and optionally rebuilds.
Conflicts are unlikely — Nominatim touches mostly new/isolated files.

## Upstream PRs Submitted

| PR | Branch | Description | Status |
|----|--------|-------------|--------|
| #598 | — | Issue: 500 on dismiss | Filed |
| #599 | fix/remove-failed-download-500 | Original dismiss fix | Open |
| #608 | fix/download-cancel-and-dismiss | Cancel button + dismiss fixes | Open |
| #609 | feat/map-geolocation-and-search | Geolocation + viewport search | Open |

If #608/#609 are merged, their changes will be in main and `sync-upstream.sh`
will skip them during rebase automatically.

## Nominatim Management

### Re-import with different region
```bash
docker rm -f nomad_nominatim
# Update PBF_URL in service DB:
docker exec nomad_mysql mysql -u nomad_user -pnomad_local_pass nomad \
  -e "UPDATE services SET installed=0, installation_status='idle' WHERE service_name='nomad_nominatim';"
# Then install from NOMAD UI
```

### Available Geofabrik US regions
- `us-northeast-latest.osm.pbf` (current) — NJ, NY, CT, MA, PA, ME, NH, RI, VT
- `us-south-latest.osm.pbf` — TX, FL, GA, NC, VA, etc.
- `us-midwest-latest.osm.pbf` — IL, OH, MI, MN, WI, etc.
- `us-west-latest.osm.pbf` — CA, WA, OR, CO, AZ, etc.
- Individual states: `us/new-jersey-latest.osm.pbf`, etc.
- Full list: https://download.geofabrik.de/north-america.html

### Backup Nominatim data
```bash
docker run --rm -v nomad-nominatim-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/nominatim-backup.tar.gz /data
```

### Restore to external SSD
```bash
# Create volume on SSD
docker volume create --driver local \
  --opt type=none --opt o=bind \
  --opt device=/Volumes/MySSD/nominatim-data \
  nomad-nominatim-data

# Restore backup
docker run --rm -v nomad-nominatim-data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/nominatim-backup.tar.gz -C /
```

## Environment (.env)

```
NOMAD_STORAGE_PATH=/Users/techyogi/source/Projects/project-nomad/storage
```
