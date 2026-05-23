#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Production upgrade flow for ERPNext.
#
# This is the ONLY supported way to upgrade. DO NOT use `docker compose pull
# && docker compose up -d` — it will restart workers against new code without
# running migrations, leaving the site in a broken state when the schema
# differs.
#
# Order enforced:
#   1. docker compose pull
#   2. start db + redis (stateful services), wait for db health
#   3. (re)run configurator with new image
#   4. start backend with new image, wait for /api/method/ping
#   5. run `bench migrate`
#   6. restore image's pre-built assets + clear caches (bootstrap
#      equivalent — needed because sites/assets is volume-persistent and
#      Redis cache holds stale DocType/hooks after a schema or hook change)
#   7. recreate ALL services with new image (load every package), then
#      re-restore assets + flush cache and restart backend + frontend
# ---------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "ERROR: .env not found in $(pwd). Copy .env.example and fill it in first." >&2
  exit 1
fi

# Load SITE_NAME from .env without sourcing the whole file
SITE_NAME="$(grep -E '^SITE_NAME=' .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
SITE_NAME="${SITE_NAME:-erpnext.example.com}"

CURRENT_TAG="$(grep -E '^IMAGE_TAG=' .env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
echo "==> Upgrading site: ${SITE_NAME}"
echo "==> Image tag in .env: ${CURRENT_TAG:-<unset, will use compose default>}"
echo

# 1. Pull new images
echo "==> [1/7] Pulling images..."
docker compose pull

# 2. Bring up stateful services first
echo "==> [2/7] Starting db, redis-cache, redis-queue..."
docker compose up -d db redis-cache redis-queue

echo "==> Waiting for db to become healthy..."
DEADLINE=$((SECONDS + 120))
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q db)" 2>/dev/null || echo unhealthy)" = "healthy" ]; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "ERROR: db did not become healthy within 120s. Aborting upgrade." >&2
    exit 1
  fi
  sleep 3
done
echo "    db is healthy."

# 3. Re-run configurator with the new image (idempotent — writes the same config)
echo "==> [3/7] Re-running configurator with new image..."
docker compose up -d --force-recreate configurator
# Wait for it to complete
DEADLINE=$((SECONDS + 60))
while [ "$(docker inspect -f '{{.State.Status}}' "$(docker compose ps -aq configurator)" 2>/dev/null || echo missing)" = "running" ]; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "ERROR: configurator did not finish within 60s. Aborting upgrade." >&2
    exit 1
  fi
  sleep 2
done
EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$(docker compose ps -aq configurator)" 2>/dev/null || echo 1)"
if [ "$EXIT_CODE" != "0" ]; then
  echo "ERROR: configurator exited with code $EXIT_CODE. Aborting upgrade." >&2
  docker compose logs --tail=100 configurator
  exit 1
fi
echo "    configurator finished."

# 4. Start backend with the new image (no deps — we control the order)
echo "==> [4/7] Starting backend with new image..."
docker compose up -d --no-deps --force-recreate backend

echo "==> Waiting for backend healthcheck..."
DEADLINE=$((SECONDS + 180))
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q backend)" 2>/dev/null || echo starting)" = "healthy" ]; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "ERROR: backend did not become healthy within 180s. Aborting upgrade." >&2
    docker compose logs --tail=100 backend
    exit 1
  fi
  sleep 5
done
echo "    backend is healthy."

# 5. Run migrations
echo "==> [5/7] Running bench migrate on ${SITE_NAME}..."
docker compose exec -T backend bench --site "${SITE_NAME}" migrate

# 6. Restore the image's pre-built assets + clear caches.
#    DO NOT run `bench build` here. The bundle files live per-container in
#    apps/<app>/public/dist (NOT in the shared `sites` volume — sites/assets
#    only holds symlinks + assets.json). `bench build` in the backend would
#    rewrite only the backend's bundles + the shared assets.json, while the
#    frontend (which actually serves /assets) keeps the old bundles — so
#    nginx 404s every freshly-hashed file ("MIME type text/html").
#    Instead restore the assets baked into the image (identical in both
#    containers) so assets.json and what the frontend serves stay in sync.
#
#    Then FLUSH the cache Redis. This is critical: Frappe caches the asset
#    manifest in a global Redis key "assets_json" that `bench clear-cache`
#    does NOT clear. Without flushing it, the backend keeps rendering the
#    PREVIOUS image's bundle hashes from cache — so every CSS/JS 404s with
#    "MIME type text/html" even though the files on disk are correct.
#    redis-cache is a pure cache (DocType metadata / hooks / website
#    fragments), so flushing it is safe and also clears the stale metadata.
echo "==> [6/7] Restoring pre-built assets and clearing caches..."
# Clear the CONTENTS of sites/assets, not the directory itself: sites/assets
# may be (or sit under) a mounted volume, and `rm -rf sites/assets` then fails
# with EBUSY ("Device or resource busy"), skipping the copy and leaving the
# old assets.json in place. `assets-dist/.` copies the contents (incl. dotfiles).
docker compose exec -T backend sh -c 'rm -rf sites/assets/* && cp -a /home/frappe/frappe-bench/assets-dist/. sites/assets/'
docker compose exec -T redis-cache redis-cli FLUSHALL
docker compose exec -T backend bench --site "${SITE_NAME}" clear-cache
docker compose exec -T backend bench --site "${SITE_NAME}" clear-website-cache

# 7. Recreate ALL services with the new image so every package/service is
#    loaded (db, redis, configurator, create-site, bootstrap, backend,
#    workers, scheduler, websocket, frontend). The one-shots are idempotent
#    (configurator/create-site are no-ops on an existing site; bootstrap
#    re-restores assets). These all reload code + re-read sites/assets/, so
#    they must come AFTER step 6 — otherwise workers run new code against
#    stale cache and frontend serves old bundles.
echo "==> [7/7] Recreating all services with the new image..."
docker compose up -d --force-recreate

# After the full recreate, re-restore the image's pre-built assets and flush
# the cache Redis once more, then restart backend + frontend so they re-read
# the freshly restored asset manifest (see step 6 for why this is required).
echo "==> Re-restoring assets, flushing cache, restarting backend + frontend..."
docker compose exec -T backend sh -c 'rm -rf sites/assets/* && cp -a /home/frappe/frappe-bench/assets-dist/. sites/assets/'
docker compose exec -T redis-cache redis-cli FLUSHALL
docker compose restart backend frontend

echo
echo "==> Upgrade complete."
docker compose ps
