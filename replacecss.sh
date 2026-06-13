#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Sync built front-end assets from the backend container to the frontend.
#
# WHY THIS EXISTS
#   `sites/assets` is a symlink to the PER-CONTAINER dir
#   /home/frappe/frappe-bench/assets (NOT a shared volume). The backend
#   renders HTML using its own content-hashed assets.json; nginx in the
#   frontend serves the physical files from ITS OWN copy. After a
#   `bench build` in the backend (the upgrade/update flow), every bundle is
#   re-hashed in the backend only, so the frontend 404s every freshly hashed
#   JS/CSS ("Refused to apply/execute ... MIME type text/html").
#
#   This script copies the backend's entire built assets dir to the frontend
#   (ALL apps -- incl. frappe/erpnext/erpnext_extensions, which the old
#   per-app loop missed, leaving desk/erpnext CSS broken). node_modules
#   (~2 GB, never served) is excluded. tar runs as root in both containers so
#   root-owned files (crm/frontend, persian_calendar, lending, ...) are
#   overwritten cleanly. Finally the backend cache Redis is flushed so it
#   re-reads its fresh manifest.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

ASSETS_DIR=/home/frappe/frappe-bench/assets

# Resolve site name (for clear-cache); falls back gracefully.
SITE_NAME="$(grep -E '^SITE_NAME=' .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
SITE_NAME="${SITE_NAME:-}"

echo "==> Syncing assets backend -> frontend (excluding node_modules)..."
docker compose exec -T --user root backend \
    tar -C "$ASSETS_DIR" --exclude=node_modules -cf - . \
  | docker compose exec -T --user root frontend \
    tar -C "$ASSETS_DIR" --overwrite -xf -
echo "    assets synced."

echo "==> Flushing backend cache Redis (stale assets_json manifest)..."
docker compose exec -T redis-cache redis-cli FLUSHALL >/dev/null
if [ -n "$SITE_NAME" ]; then
  docker compose exec -T backend bench --site "$SITE_NAME" clear-cache || true
  docker compose exec -T backend bench --site "$SITE_NAME" clear-website-cache || true
fi

echo "==> Done. Hard-refresh the browser (Ctrl/Cmd-Shift-R)."
