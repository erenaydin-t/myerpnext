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
# Frappe apps (frappe user)
#   Grouped into logical RUN layers so Docker can cache them independently
#   and a failure surfaces the responsible group.
# ---------------------------------------------------------------------------
USER frappe
WORKDIR /home/frappe/frappe-bench

# pnpm 10 made ignored build scripts a fatal install error. Modern
# Frappe Vue apps (wiki, crm, helpdesk, drive, lms, insights) transitively
# pull native deps that REQUIRE install scripts (@parcel/watcher,
# @swc/core, esbuild, canvas, core-js, vue-demi).
#
# Fix via a user-level .npmrc at /home/frappe/.npmrc. .npmrc is read by
# every pnpm invocation, including the pnpm version that corepack
# downloads behind `yarn install`. (An env var alone is not enough —
# corepack-managed pnpm doesn't reliably inherit it.)
#
# Safe in this image: every package present comes from a repo we
# explicitly trust in apps.json.
RUN printf '%s\n' \
      'auto-install-peers=true' \
      'strict-peer-dependencies=false' \
      'dangerously-allow-all-builds=true' \
      > /home/frappe/.npmrc

# Keep the env var as a belt-and-suspenders fallback for any pnpm
# version that honors npm_config_* over .npmrc precedence.
ENV npm_config_dangerously_allow_all_builds=true

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
    bench get-app --skip-assets https://github.com/frappe/wiki && \
    bench get-app --skip-assets https://github.com/frappe/drive

# Group 3: Third-party / custom apps
RUN bench get-app --skip-assets https://github.com/sfarbod/ERPNext_Extensions && \
    bench get-app --skip-assets https://github.com/sfarbod/persian_calendar_ERPNext && \
    bench get-app --skip-assets https://github.com/The-Commit-Company/raven && \
    bench get-app --skip-assets https://github.com/erenaydin-t/dms && \
    bench get-app --skip-assets https://github.com/erenaydin-t/logto_bridge.git

# Build frontend assets once, after every app is installed
RUN bench build --force

# Persist resolved ERPNext version inside the image for runtime diagnostics
RUN echo "${ERPNEXT_VERSION}" > /home/frappe/frappe-bench/ERPNEXT_VERSION
