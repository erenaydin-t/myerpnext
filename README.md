# ERPNext v16 — Custom Build

Production Docker deployment for ERPNext **version-16** with a curated set of
Frappe and third-party apps. The image is built by GitHub Actions, published to
GHCR with the exact ERPNext semver as its tag (e.g. `v16.18.0`), and consumed
on the server with `docker compose up -d` for the first boot and `./upgrade.sh`
for every subsequent upgrade.

---

## What's inside the image

Built on top of `frappe/erpnext:version-16` with extra OS packages
(LibreOffice, Tesseract OCR incl. Persian, poppler, libmagic) and the
following apps:

| Group              | Apps                                                   |
| ------------------ | ------------------------------------------------------ |
| Frappe core (v16)  | `payments`, `hrms`, `lending`, `crm`, `telephony`      |
| Frappe independent | `helpdesk`, `lms`, `insights`, `wiki`                  |
| Third-party        | `erpnext_extensions`, `persian_calendar`, `raven`, `dms`, `logto_bridge` |

> ⚠️ **`frappe/drive` is excluded from the image.** Drive ships a yarn
> `postinstall` hook (`scripts/install-pnpm.sh`) that hard-pins pnpm 11
> via corepack — pnpm 11 makes `ERR_PNPM_IGNORED_BUILDS` a fatal install
> error, so the build aborts. Drive is upstream-beta anyway. Re-add it to
> the `Dockerfile` and `apps.json` once upstream stabilises that script.

The full list with branches is in [`apps.json`](apps.json).

---

## Repository layout

```
.
├── Dockerfile                       # Custom image (FROM frappe/erpnext:version-16)
├── apps.json                        # Canonical list of installed apps
├── docker-compose.yml               # Server-side deployment
├── upgrade.sh                       # The ONLY supported upgrade path
├── .env.example                     # Template for server-side .env
├── scripts/
│   └── verify-app-slugs.sh          # Print actual app module names in the image
├── deploy/
│   └── logrotate-frappe             # logrotate config for the `logs` volume
└── .github/workflows/docker-build.yml  # CI: preflight + build + push to GHCR
```

---

## Image versioning

CI extracts the exact ERPNext version from `apps/erpnext/erpnext/__init__.py`
inside the base image and tags the build with it. Every push to `main`
(and the weekly Sunday cron) publishes:

| Tag                       | Meaning                                  |
| ------------------------- | ---------------------------------------- |
| `v16.18.0`                | Exact ERPNext semver (**pin this in production**) |
| `v16-latest`              | Latest build of the v16 line             |
| `v16-YYYYMMDD`            | Dated snapshot                           |
| `sha-abc1234`             | Git revision                             |
| `latest`                  | Latest build on the default branch       |

Resolved version is also embedded as an OCI label
(`org.opencontainers.image.version`) and written to
`/home/frappe/frappe-bench/ERPNEXT_VERSION` inside the image.

---

## CI/CD

`.github/workflows/docker-build.yml` runs on:

- every push to `main`
- manual `workflow_dispatch`
- weekly cron (Sunday 03:00 UTC) so upstream Frappe/ERPNext patches roll in

Before building, the workflow does a **preflight access check** that runs
`git ls-remote` against every URL + branch in `apps.json`. If any repo was
deleted, renamed, or went private, the job fails fast with a clear error
listing exactly which repos broke — no half-baked image is ever pushed.

If one of your own repos (`erenaydin-t/*`) needs to go private:

1. Create a PAT with `repo:read` on those repos.
2. Add it as `secrets.APPS_GITHUB_TOKEN` in the repo settings.
3. Uncomment the `git config` line in the preflight step of the workflow.

To consume the image on a private GHCR package, generate a PAT with
`read:packages` on the server and run:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
```

### Verifying app slugs (do this once after the first build)

Repo names and Python module names often differ
(`ERPNext_Extensions` → `erpnext_extensions`, `persian_calendar_ERPNext` →
`persian_calendar`). The `--install-app` flag wants the **module name**.
Confirm what the image actually contains:

```bash
./scripts/verify-app-slugs.sh ghcr.io/erenaydin-t/myerpnext:v16-latest
```

If any printed slug doesn't match an `--install-app` flag in
`docker-compose.yml` under `create-site`, **edit it before first deploy**.
Fixing it after `create-site` has partially run requires manually dropping
the orphaned MariaDB database.

---

## Server deployment

### 1. Prerequisites

- Linux host with Docker Engine ≥ 24 and the Compose v2 plugin
- **Minimum 8 GB RAM / 2 vCPU**; recommended **16 GB / 4 vCPU**. No Docker
  resource limits are applied — services use the full host. Size the host
  (RAM + swap) for your workload; see [Resource sizing](#resource-sizing).
- DNS pointing your site name (e.g. `erpnext.example.com`) at the host
- A reverse proxy in front (Nginx / Caddy / Traefik) terminating TLS and
  forwarding to **`127.0.0.1:9090`** — by default the compose stack binds the
  frontend to loopback only so it can never be reached over plain HTTP from
  outside. To put a **CDN/WAF** in front instead (it terminates TLS), set
  `FRONTEND_PORT_BINDING=0.0.0.0:80:8080` in `.env` to expose HTTP on port 80
  — and firewall that port to your CDN's IP ranges (see `.env.example`).

### 2. Get the deployment files

```bash
mkdir -p /opt/erpnext && cd /opt/erpnext
curl -O https://raw.githubusercontent.com/erenaydin-t/myerpnext/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/erenaydin-t/myerpnext/main/upgrade.sh
curl -O https://raw.githubusercontent.com/erenaydin-t/myerpnext/main/.env.example
chmod +x upgrade.sh
cp .env.example .env
```

### 3. Configure `.env`

```bash
GHCR_IMAGE=ghcr.io/erenaydin-t/myerpnext
IMAGE_TAG=v16.18.0                  # pin to the exact published tag
SITE_NAME=erpnext.example.com
DB_ROOT_PASSWORD=<long-random-string>
ADMIN_PASSWORD=<long-random-string>
```

> Always pin `IMAGE_TAG` to an exact semver in production. `v16-latest` is
> fine for staging but will silently move under you.

No resource limits are configured, so there is nothing to tune per host —
every service may use the full host capacity. See [Resource sizing](#resource-sizing)
for guidance on sizing the host itself.

### 4. First boot

```bash
docker compose pull
docker compose up -d
```

What happens on first boot:

1. `db` starts and becomes healthy
2. `configurator` writes `sites/common_site_config.json`, then exits
3. `create-site` creates the site and installs every app, then exits
4. `bootstrap` rebuilds assets and clears caches, then exits
5. `backend`, `queue-long`, `queue-short`, `scheduler`, `websocket` come up
6. `frontend` comes up once `backend` is healthy

Long-running services (backend, workers, scheduler, websocket, frontend)
**all wait for `bootstrap`** to complete — no worker ever starts against
stale assets or stale cache. See [Startup & cache invariants](#startup--cache-invariants).

> ⏱️ **First boot takes 12–25 minutes** total. Breakdown:
>
> - `create-site` 10–20 min (installs 15 apps, runs migrations, fixtures)
> - `bootstrap` 1–2 min (`bench build --force` + cache clears)
> - `backend` warmup 0.5–1 min (first /api/method/ping after metadata load)
>
> **Do not assume failure early.** Watch live:
>
> ```bash
> docker compose logs -f create-site bootstrap backend
> ```
>
> If the most recent service is still printing migration / patch / fixture /
> build lines, it's working. Real failure = the container has exited with a
> non-zero code (`docker compose ps`).

The stack is ready when `frontend` responds on `http://127.0.0.1:9090`.

### 5. Put TLS in front

Example Nginx vhost (terminate TLS, forward to the loopback-bound frontend):

```nginx
server {
    listen 443 ssl http2;
    server_name erpnext.example.com;

    ssl_certificate     /etc/letsencrypt/live/erpnext.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/erpnext.example.com/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;

        # Websocket upgrade for the live socketio endpoint
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### 6. Install log rotation on the host

The compose stack already rotates Docker container logs (`max-size: 10m`,
`max-file: 5` via the json-file driver). Frappe's own log files inside the
`logs` volume need host-side `logrotate`:

```bash
sudo cp deploy/logrotate-frappe /etc/logrotate.d/frappe-erpnext
sudo logrotate -d /etc/logrotate.d/frappe-erpnext   # dry-run
sudo logrotate    /etc/logrotate.d/frappe-erpnext   # force first rotation
```

The shipped config assumes the compose project is named `erpnext` (set via
`name: erpnext` in `docker-compose.yml`). If you change the project name,
update the volume path in `deploy/logrotate-frappe` accordingly.

---

## Resource sizing

**No Docker resource limits are configured.** `docker-compose.yml` sets no
`memory` or `cpus` caps on any service, so every container may use the full
host capacity. This is deliberate: cgroup memory caps cause OOM kills
(exit 137) during memory-heavy operations such as `bench build`, where
Frappe sizes Node's heap from *host* RAM and overshoots a small per-container
cap.

Because there are no limits, sizing is about the **host**, not the
containers:

- **RAM.** Provision enough for MariaDB's InnoDB buffer pool + Frappe
  gunicorn workers + DMS OCR (Tesseract/LibreOffice can use 1–2 GB per job)
  running concurrently. 16 GB is comfortable; 8 GB is the practical floor.
- **Swap.** Add swap (e.g. 4 GB) as a safety margin for build/OCR bursts:

  ```bash
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```

- **Co-tenancy.** Since nothing is capped, don't run unrelated heavy
  services on the same host — the stack will use whatever it needs.

If you ever need to constrain a single service (e.g. on a shared host),
add a `deploy.resources.limits` block back to that service in
`docker-compose.yml` manually.

---

## Startup & cache invariants

The stack guarantees the following before any long-running service starts:

| Invariant                                | Enforced by                                   |
| ---------------------------------------- | --------------------------------------------- |
| `common_site_config.json` exists         | `configurator` (one-shot)                     |
| Site exists with all apps installed      | `create-site` (one-shot, idempotent)          |
| `sites/assets/` matches the current image | `bootstrap` runs `bench build --force`        |
| Redis metadata cache is fresh            | `bootstrap` runs `bench clear-cache`          |
| Website cache is fresh                   | `bootstrap` runs `bench clear-website-cache`  |
| Backend answers `/api/method/ping`       | `backend` healthcheck (start_period 180s)     |
| Workers / scheduler / websocket started  | Each depends on `bootstrap` completed         |
| Frontend serves traffic                  | Depends on `backend` healthy                  |

Why this matters:

- **`sites/assets/` is on the persistent `sites` volume.** After the first
  boot, that volume retains the OLD image's built assets and masks the NEW
  image's pre-built ones. `bench build --force` rewrites them in place.
- **Redis holds DocType metadata, hooks, and website fragments.** A new
  image with new hooks but cached old metadata = subtle wrong behavior, not
  loud failure. `clear-cache` + `clear-website-cache` purge it.
- **Workers cache module imports in-process.** Restarting them with new
  code AFTER assets and Redis are refreshed prevents "new code reading
  stale cache" race conditions.

This is enforced in two places:

1. **Compose (`bootstrap` service)** — runs after `create-site`, gates every
   long-running service via `depends_on: bootstrap: service_completed_successfully`.
   Re-runs whenever `pull_policy: always` pulls a new image and a `compose up`
   force-recreates the chain.
2. **`./upgrade.sh`** — does the same work inline (steps 5–6) because the
   script uses `--no-deps` to control restart order and therefore bypasses
   compose's dependency graph.

If you ever bypass both (e.g. `docker pull <new image> && docker compose
restart backend`), expect stale assets and stale cache. Don't do that.

---

## Upgrading — use `./upgrade.sh`, never plain `compose up`

`docker compose pull && docker compose up -d` is the wrong upgrade path: it
restarts workers and scheduler against new code **before** running
`bench migrate`, leaving the site in a broken state whenever the schema
changes.

The supported flow is `./upgrade.sh`, which enforces:

1. `docker compose pull`
2. Start `db`, `redis-cache`, `redis-queue`, wait for db health
3. Re-run `configurator` (idempotent)
4. Start `backend` with the new image, wait for `/api/method/ping`
5. Run `bench migrate` on the site
6. `bench build --force` + `clear-cache` + `clear-website-cache`
7. Restart `queue-long`, `queue-short`, `scheduler`, `websocket`, `frontend`

```bash
# 1. Edit .env to set the new IMAGE_TAG=vX.Y.Z
# 2. Run the wrapper
./upgrade.sh
```

The script aborts loudly if db doesn't become healthy, configurator exits
non-zero, the backend healthcheck doesn't pass, migrate fails, or any of
the build / cache-clear commands fail.

---

## Day-2 operations

### Run a bench command

```bash
docker compose exec backend bench --site erpnext.example.com <command>
# e.g. clear-cache, console, list-apps, version
```

### Manual backup (automated backups not yet implemented)

```bash
docker compose exec backend bench --site erpnext.example.com backup --with-files
docker compose cp backend:/home/frappe/frappe-bench/sites/erpnext.example.com/private/backups ./backups
```

### Logs

```bash
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs --tail=200 queue-long scheduler
```

Backend has a healthcheck against `/api/method/ping`; current state:

```bash
docker inspect --format '{{.State.Health.Status}}' $(docker compose ps -q backend)
```

### Stop / restart

```bash
docker compose stop          # graceful
docker compose down          # stop + remove containers (volumes preserved)
docker compose down -v       # DANGER: also removes volumes (db, sites, …)
```

---

## Verifying which ERPNext version is running

```bash
docker compose exec backend cat ERPNEXT_VERSION
# or
docker compose exec backend bench --site erpnext.example.com version
```

OCI label on the published image:

```bash
docker inspect ghcr.io/erenaydin-t/myerpnext:v16.18.0 \
  --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'
```

---

## Troubleshooting

| Symptom                                          | Likely cause / fix                                                                                   |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `create-site` exits with `App ... not found`     | The `--install-app` slug doesn't match the actual module name. Run `./scripts/verify-app-slugs.sh` and update `docker-compose.yml`. |
| `create-site` running for >20 min, no errors     | Normal on first boot. Tail `docker compose logs -f create-site` — if lines are still appearing, wait. |
| `create-site` hangs on "Waiting for configurator…" | `configurator` failed. Check `docker compose logs configurator`. Usually wrong DB credentials.        |
| `bootstrap` exits non-zero / backend never starts | `docker compose logs bootstrap`. Usually a `bench build` failure from a broken app, or wrong `SITE_NAME` env. |
| Frontend serves stale bundles after image change | Bypassed both bootstrap and `upgrade.sh`. Run `./upgrade.sh` or `docker compose up -d --force-recreate bootstrap` then `docker compose restart frontend`. |
| Backend healthcheck stuck in `starting`          | Site config still loading. Give it 60s. If still failing, `docker compose logs backend`.              |
| 502 from Nginx                                   | `backend` not healthy yet. `docker compose ps` and check the Health column.                          |
| `denied: permission_denied` on `docker pull`     | GHCR login missing or PAT lacks `read:packages`.                                                     |
| OCR not detecting Persian text in DMS            | Confirm `tesseract-ocr-fas` is present: `docker compose exec backend dpkg -l | grep tesseract`.      |
| Frontend serves stale assets after upgrade       | `docker compose exec backend bench build --force && docker compose restart frontend`.                |
| Workflow fails at "Verify app repository access" | A repo in `apps.json` was deleted / renamed / went private. Fix the URL, or wire `APPS_GITHUB_TOKEN`. |

---

## Security checklist before going live

- [ ] `.env` contains long random `DB_ROOT_PASSWORD` and `ADMIN_PASSWORD` (not the defaults)
- [ ] `.env` is `chmod 600` and **not** committed to git
- [ ] `IMAGE_TAG` pinned to an exact semver, not `v16-latest`
- [ ] Frontend port binding is correct for your ingress: loopback (default `127.0.0.1:9090:8080`) behind a host reverse proxy, OR `0.0.0.0:80:8080` via `FRONTEND_PORT_BINDING` with the host firewall locked to your CDN's IPs
- [ ] TLS terminated at the reverse proxy
- [ ] Redis ports are **not** exposed publicly (no `ports:` block on either redis service — leave it that way)
- [ ] App slugs verified with `./scripts/verify-app-slugs.sh` against the built image
- [ ] Host has enough RAM (+ swap) for the workload — no per-container limits are set (see [Resource sizing](#resource-sizing))
- [ ] Upgrades go through `./upgrade.sh`, not plain `docker compose up`
- [ ] logrotate config installed on the host (`deploy/logrotate-frappe`)
- [ ] Backup strategy planned (manual command available today; automation pending)
- [ ] GHCR package visibility set to private if any installed app is proprietary
