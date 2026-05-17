#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Print the actual Frappe app module names (slugs) in the built image.
#
# These are the strings `bench new-site --install-app` expects. The repo
# name and the module slug differ for several apps (e.g. ERPNext_Extensions
# -> erpnext_extensions, persian_calendar_ERPNext -> persian_calendar).
#
# Run this once after the first GHCR build, then update the
# `--install-app` flags in docker-compose.yml::create-site if any slug
# doesn't match what you expected.
#
# Usage:
#   ./scripts/verify-app-slugs.sh [IMAGE]
# ---------------------------------------------------------------------------

set -euo pipefail

IMAGE="${1:-ghcr.io/erenaydin-t/dockererpnext:v16-latest}"

echo "Pulling ${IMAGE}..."
docker pull "${IMAGE}" >/dev/null

echo
echo "Slugs available in the image (pass these to --install-app):"
echo "-----------------------------------------------------------"
docker run --rm --entrypoint ls "${IMAGE}" /home/frappe/frappe-bench/apps

echo
echo "Compare against the --install-app flags in docker-compose.yml."
echo "If anything differs, edit create-site.command BEFORE first deploy —"
echo "fixing it afterwards requires manually dropping the orphaned DB."
