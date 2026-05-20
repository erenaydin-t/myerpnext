# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=frappe/erpnext:version-16
FROM ${BASE_IMAGE}

# Build-args injected by GitHub Actions for traceability
ARG ERPNEXT_VERSION=unknown
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="ERPNext v16 - Custom Build" \
      org.opencontainers.image.description="ERPNext v16 with HRMS, CRM, Helpdesk, Insights, Wiki, Drive, Raven, DMS (OCR), Persian Calendar, Logto Bridge" \
      org.opencontainers.image.version="${ERPNEXT_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/erenaydin-t/dockererpnext" \
      io.frappe.erpnext.version="${ERPNEXT_VERSION}"

# ---------------------------------------------------------------------------
# OS dependencies (root)
#   - LibreOffice + fonts:   PDF rendering (print formats, exports)
#   - poppler-utils:         pdf2image / DMS preview generation
#   - tesseract-ocr (+fas):  DMS OCR pipeline incl. Persian
#   - libmagic1:             python-magic for DMS file-type detection
#   - build-essential et al: any wheel that still needs compilation
# ---------------------------------------------------------------------------
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pkg-config \
        build-essential \
        default-libmysqlclient-dev \
        libreoffice-core \
        libreoffice-writer \
        fonts-dejavu \
        libmagic1 \
        poppler-utils \
        tesseract-ocr \
        tesseract-ocr-eng \
        tesseract-ocr-fas \
        libffi-dev \
        libssl-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Pin pnpm to 9.15.4 via corepack.
#
# Why: modern Frappe Vue apps (wiki, crm, helpdesk, drive, lms, insights)
# pin `packageManager: pnpm@11.x` in their package.json. Corepack honors
# that and downloads pnpm 11 to run `bench get-app -> yarn install`. pnpm
# 10 made ignored build scripts a fatal install error, and pnpm 11 removed
# the `dangerously-allow-all-builds` escape config — so both `.npmrc` and
# `NPM_CONFIG_*` env-var approaches are silently ignored. The only
# documented escape in pnpm 11 is `pnpm approve-builds`, which is
# interactive and can't run during an image build.
#
# pnpm 9 emits the same ERR_PNPM_IGNORED_BUILDS as a WARNING, not a fatal
# error, so installs proceed. Lockfile format 9.0 is shared by pnpm 9/10/11
# so the committed pnpm-lock.yaml files in the upstream apps still resolve.
#
# COREPACK_ENABLE_PROJECT_SPEC=0 tells corepack to ignore each project's
# `packageManager` field and always use the version we activated below.
# ---------------------------------------------------------------------------
USER root
ENV COREPACK_ENABLE_PROJECT_SPEC=0
RUN corepack prepare pnpm@9.15.4 --activate

USER frappe
WORKDIR /home/frappe/frappe-bench

# Modern Frappe apps still benefit from these defaults under pnpm 9.
RUN printf '%s\n' \
      'auto-install-peers=true' \
      'strict-peer-dependencies=false' \
      > /home/frappe/.npmrc

# ---------------------------------------------------------------------------
# Frappe apps. Grouped into logical RUN layers so Docker can cache them
# independently and a failure surfaces the responsible group.
# ---------------------------------------------------------------------------

# Group 1: Frappe-maintained apps pinned to version-16 branch
RUN bench get-app --branch version-16 --skip-assets https://github.com/frappe/payments && \
    bench get-app --branch version-16 --skip-assets https://github.com/frappe/hrms

# Group 2: Independent Frappe-maintained apps (own release cadence).
# These do not publish version-XX branches — they roll forward from
# develop / main. Weekly cron rebuilds will pull whatever HEAD is.
RUN bench get-app --branch develop --skip-assets https://github.com/frappe/lending && \
    bench get-app --branch main    --skip-assets https://github.com/frappe/crm && \
    bench get-app --branch develop --skip-assets https://github.com/frappe/telephony && \
    bench get-app --skip-assets https://github.com/frappe/helpdesk && \
    bench get-app --skip-assets https://github.com/frappe/lms && \
    bench get-app --skip-assets https://github.com/frappe/insights && \
    bench get-app --skip-assets https://github.com/frappe/wiki
# NOTE: frappe/drive intentionally NOT installed here. Drive ships a yarn
# postinstall hook (scripts/install-pnpm.sh) that hard-pins pnpm 11 via
# corepack, overriding our global pin and reintroducing the
# ERR_PNPM_IGNORED_BUILDS fatal error. Drive is upstream-beta anyway; the
# tradeoff is not worth blocking the build. To re-enable once upstream
# stabilises, add it back here and to apps.json.

# Group 3: Third-party / custom apps
RUN bench get-app --skip-assets https://github.com/sfarbod/ERPNext_Extensions && \
    bench get-app --skip-assets https://github.com/sfarbod/persian_calendar_ERPNext && \
    bench get-app --skip-assets https://github.com/The-Commit-Company/raven && \
    bench get-app --skip-assets https://github.com/erenaydin-t/dms && \
    bench get-app --skip-assets https://github.com/erenaydin-t/logto_bridge.git

# Modern Frappe apps (crm, helpdesk, wiki, insights, lms) have vite
# frontends that statically import values from sites/common_site_config.json
# at BUILD time (e.g. `import { socketio_port } from '.../common_site_config.json'`).
# At image-build time that file doesn't exist yet — the configurator service
# writes it on first `compose up`. Without this stub, `bench build` fails:
#   src/socket.js: "socketio_port" is not exported by common_site_config.json
#
# These stub values MUST match what docker-compose.yml::configurator writes
# at runtime, otherwise the values baked into the JS bundles will diverge
# from what the live services use. configurator may extend the file with
# additional keys at runtime; it never rewrites keys it doesn't set.
RUN cat > sites/common_site_config.json <<'EOF'
{
  "db_host": "db",
  "db_port": 3306,
  "redis_cache": "redis://redis-cache:6379",
  "redis_queue": "redis://redis-queue:6379",
  "redis_socketio": "redis://redis-queue:6379",
  "socketio_port": 9000,
  "webserver_port": 8000
}
EOF

# Build frontend assets after every app is installed.
#
# We build ONE APP AT A TIME instead of `bench build --force` (which builds
# every app in a single pass). The combined build holds the Vite/esbuild
# module graphs of all ~14 apps in memory at once — with heavy Vue frontends
# (crm, helpdesk, wiki, insights, lms, raven, hrms) peak RSS exceeds the RAM
# on small build hosts and the kernel OOM-killer terminates the build (exit
# 137 / "Killed"). Building per-app keeps each invocation's working set small
# so peak memory stays bounded.
#
# NODE_OPTIONS caps V8's JS heap as a secondary guard rail. Raise it if a
# single large app still hits "JavaScript heap out of memory"; lower it if the
# host is very tight on RAM.
ENV NODE_OPTIONS=--max-old-space-size=2048
RUN set -eu; \
    for app in $(cat sites/apps.txt); do \
      echo "==> bench build --app ${app}"; \
      bench build --force --app "${app}"; \
    done

# Stash the freshly built assets OUTSIDE the sites/ tree.
#
# At runtime the `sites` named volume is mounted over /sites, so it MASKS the
# image's pre-built sites/assets on every boot after the first. Keeping a copy
# here (frappe-bench/ is part of the image, never volume-mounted) lets the
# compose `bootstrap` service restore them with a fast `cp` — no `bench build`
# at runtime, so no OOM and no waiting. assets-dist is the source of truth for
# the bundled CSS/JS shipped in this image.
RUN cp -a sites/assets /home/frappe/frappe-bench/assets-dist

# Persist resolved ERPNext version inside the image for runtime diagnostics
RUN echo "${ERPNEXT_VERSION}" > /home/frappe/frappe-bench/ERPNEXT_VERSION
