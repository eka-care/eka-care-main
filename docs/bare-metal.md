# Deploying `eka-webhook` on bare metal / a VM / locally (no AWS)

This is the non-AWS deployment path: a single interactive installer
(`deploy-local.sh`) that runs the service via Docker Compose on any Linux
host - a bare-metal server, a generic VM (on-prem, any cloud), or a local
box for testing. For AWS (Lambda + API Gateway via CloudFormation), see
[aws.md](./aws.md) instead.

## Prerequisites

- A Linux host (bare metal or VM). macOS/Windows are not supported by this
  script.
- Outbound HTTPS (443) access to: `www.eka.care`, `api.eka.care` (webhook
  auth/registration), the app image's Docker registry (Docker Hub by default,
  or your own private registry if using `--image`), `get.docker.com` (unless
  Docker is already installed or you pass `--skip-docker-install`), `github.com`
  and `objects.githubusercontent.com` (Docker Compose CLI plugin download -
  `get.docker.com/rootless` installs the Docker engine itself but not this,
  so it's fetched separately whenever `docker compose` isn't already working),
  and - if you want managed SSL - Docker Hub as well (nginx/certbot images
  always come from there, even if `--image` points the app at a private
  registry), Let's Encrypt, and (best-effort, non-blocking)
  `checkip.amazonaws.com` for the DNS sanity check. The installer checks every
  required one of these during preflight, retrying with backoff before
  failing (client firewalls commonly block one or more of them), reports
  every blocked endpoint together rather than stopping at the first, and
  prints the exact reason (DNS failure, connection refused, timeout, ...) for
  each one that's unreachable.
- `curl` and `jq`. Not installed? No action needed - the installer detects
  what's missing, works out the right package for your `apt-get`/`dnf`/
  `yum`/`zypper`, and asks before installing anything via sudo. (`openssl`
  is *not* required - it's not used for SSL/TLS at all here, since certbot
  runs inside the nginx container; the only place it was used on the host
  was to generate a random `SIGNING_KEY`, which now comes straight from
  `/dev/urandom` instead.)
- Root/sudo access may be needed, but only briefly, for: installing `curl`/
  `jq` if missing (above), installing Docker's own rootless-mode
  prerequisites (`iptables`, `uidmap`/`shadow-utils`/`shadow`, depending on
  your package manager) if they're not already on the box, loading the
  `nf_tables` and/or `ip_tables` kernel modules if they aren't already loaded
  (whichever the host's iptables backend needs - `nf_tables` for nftables,
  e.g. Amazon Linux 2023; `ip_tables` for the legacy backend, e.g. Ubuntu -
  rootless Docker's own setup script refuses to proceed without them even
  after the `iptables` package itself is installed) - same detect-and-ask
  flow (asked once for both) - installing an AppArmor profile on Ubuntu
  23.10+/24.04+ (which restricts unprivileged user namespaces by default,
  breaking rootlesskit with "permission denied" otherwise) - and, if you
  choose managed SSL on a rootless Docker setup, binding ports 80/443 (see
  below).
- If you already manage Docker yourself (Ansible, Chef, golden image, ...),
  pass `--skip-docker-install` and the script will just verify it's present.

## Quick start

```bash
git clone <this-repo> && cd eka-webhook
./deploy-local.sh install
```

`config.env` isn't tracked in git - the first run creates it from
`config.env.example` automatically (no separate step needed). You can
also pre-fill it yourself before running (`cp config.env.example
config.env && vim config.env`) if you'd rather not answer
prompts interactively.

The installer walks through, in order: system/URL checks, Docker install (if
needed), a dedicated Docker network, SSL mode selection, secrets/env
collection, config validation, image build + container start, a health
check, and webhook registration with Eka Care. It's resumable - re-running
`install` skips steps already marked done and only re-prompts for
missing/invalid values.

## `config.env`

This is the single source of truth for configuration and secrets on the
local/VM path (same role `config-aws.env` plays for the AWS path). The
installer sources it, prompts only for blank/placeholder values, and writes
answers back into the file. Once populated it holds real secrets - the
installer `chmod 600`s it, and it should never leave this host (it's
gitignored; only the placeholder `config.env.example` is tracked).

If you'd rather hand-craft `config.env` yourself (`cp
config.env.example config.env && vim config.env`) than
answer prompts, that's supported directly: if the file already exists when
you run `install`, the installer shows a summary of what's configured
(secrets masked) and asks once whether to use it as-is. Confirm, and it
proceeds without walking through each already-set value individually - any
field you left blank is still prompted for (or generated, for `SIGNING_KEY`)
as usual. This only affects config *values* - sudo confirmations for system
changes (installing Docker, kernel modules, etc.) are unaffected and still
asked normally.

| Variable | Meaning |
|---|---|
| `PORT` | Port the app listens on (default `8080`) |
| `EXTERNAL_URL` | Public URL clients/Eka Care will reach this service on |
| `APP_IMAGE` | Pre-built image to run, e.g. `ekacare/ekapython-webhook-sdk:v1.2.3` ([available tags](https://hub.docker.com/repository/docker/ekacare/ekapython-webhook-sdk/general)). Leave blank to build from the local Dockerfile instead. Set via prompt on `install`, or `./deploy-local.sh upgrade --image <ref>` (which also persists it here for future runs) |
| `SSL_MODE` | `managed` (we run nginx+certbot for you) or `external` (you already terminate TLS in front of this host) |
| `HTTP_PORT`, `HTTPS_PORT` | Ports nginx publishes, only used when `SSL_MODE=managed` (default `80`/`443`). `HTTP_PORT` must stay `80` unless something else forwards the public port 80 to it - Let's Encrypt's HTTP-01 challenge always connects on port 80 |
| `CLIENT_NAME` | Which integration to load from `config.yaml` - `metropolis` or `miracles` |
| `CLIENT_ID`, `CLIENT_SECRET`, `API_KEY` | Eka Care registration credentials (required) |
| `SIGNING_KEY` | Webhook signature key - leave blank and the installer generates one |
| `YELLOW_AI_API_KEY`, `JAPI_KEY`, `JAPI_AUTHORIZATION` | Messaging integration secrets, only needed for `CLIENT_NAME=metropolis` |

## SSL modes

There is a single `docker-compose.yml`. `deploy-local.sh` - not the compose
file - decides what runs: it activates nginx/certbot via Docker Compose's
`--profile ssl` flag only when needed, and controls whether the app is
publicly reachable via the `APP_BIND_ADDR` environment variable.

- **`external`** (default): you already have a reverse proxy/load balancer
  terminating TLS in front of this host. The installer publishes the app on
  `0.0.0.0:$PORT` and does nothing else SSL-related (no `--profile ssl`).
- **`managed`**: the installer runs `docker compose --profile ssl ...`,
  which brings up nginx + certbot in addition to the app, and binds the
  app's published port to `127.0.0.1` only (`APP_BIND_ADDR=127.0.0.1`) so
  it's reachable exclusively through nginx. This is a two-phase bootstrap:
  nginx first serves the ACME HTTP-01 challenge over plain HTTP on port 80,
  certbot issues the certificate against `EXTERNAL_URL`'s domain, then
  nginx is reloaded with the 443 server block enabled. Renewal runs
  automatically inside the `certbot` container (`certbot renew` on a loop).
  Requires DNS for that domain to already point at this host's public IP -
  the installer does a non-blocking sanity check for this before attempting
  issuance.

nginx configuration lives in `nginx/`:
- `nginx.conf.example` - always active; serves the ACME challenge and
  proxies to the app on port 80. Rendered (envsubst, domain/port filled in)
  to `nginx/nginx.conf`, which overwrites the nginx image's own
  `conf.d/default.conf` so there's no ambiguity with its stock welcome page.
- `nginx-https.conf.example` - the 443 server block, added only once a
  certificate exists. Rendered to `nginx/ssl-enabled/nginx-https.conf`.
  Until a cert is issued, `nginx/ssl-enabled/` stays empty and nginx simply
  runs HTTP-only on port 80 - no error, no 443 listener.

Both rendered files are gitignored (installer-generated, host-specific).

## Commands

```bash
./deploy-local.sh install                 # first-time / resume install
./deploy-local.sh install --dry-run       # preview every action, no mutation
./deploy-local.sh status                  # show step state + container status
./deploy-local.sh upgrade --image <ref>   # deploy a specific pre-built image (also saved to config.env)
./deploy-local.sh upgrade                 # re-deploy the currently configured APP_IMAGE (or rebuild locally if unset)
./deploy-local.sh register-webhook        # (re-)register only, no other steps
./deploy-local.sh stop                    # stop + remove containers only (config/volumes/certs kept)
./deploy-local.sh uninstall               # stop + remove containers AND volumes (certs, any app data)
```

Useful flags on `install`/`upgrade`: `--fresh` (ignore saved step state),
`--debug` (verbose), `--non-interactive` (fail instead of prompting - use
with everything pre-filled in `config.env`), `--port`,
`--external-url`, `--ssl-mode managed|external`, `--skip-docker-install`.

Every `[y/N]` confirmation during install (installing missing packages,
loading kernel modules, sudo steps, etc.) also accepts `a`/`A` - "yes to
all", same convention as many Linux package managers - which answers yes to
that prompt and every remaining confirmation for the rest of the run, so you
don't need to type `y` a dozen separate times on a fresh host.

## State and logs

- Step-completion state: `~/.eka-deploy/state.json` (`chmod 600`, no secrets
  in it - just which steps are done, for idempotent resume).
- Container logs: `./deploy-local.sh status`, or directly:
  `docker compose --env-file config.env -f docker-compose.yml
  [--profile ssl] logs -f app`
- Log rotation is handled by Docker's `json-file` driver (10MB x 5 files per
  container) - no host-level logrotate setup needed.

## Troubleshooting

- **"cannot reach api.eka.care:443" / registry / Let's Encrypt**: the
  installer checks these upfront and names the blocked endpoint - check
  your firewall/proxy allowlist.
- **Webhook registration fails after retries**: fix whatever it reported
  (usually credentials or `EXTERNAL_URL` not reachable from the internet
  yet), then re-run `./deploy-local.sh register-webhook` - no need to redo
  the whole install.
- **Certbot issuance fails**: almost always DNS not pointing at this host
  yet. Fix DNS, then re-run `install` (it picks up from the `build_and_start`
  step since earlier steps are already marked done).
