#!/bin/bash
# Interactive installer for the eka-webhook service on bare metal / VM / local
# Linux hosts (no AWS dependency). See docs/bare-metal.md for full documentation.
#
# Usage: ./deploy-local.sh [install|upgrade|uninstall|status|register-webhook|help] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config-local.env"
STATE_DIR="$HOME/.eka-deploy"
STATE_FILE="$STATE_DIR/state.json"

# shellcheck source=lib/register-webhook.sh
source "$SCRIPT_DIR/lib/register-webhook.sh"
# shellcheck source=lib/connectivity.sh
source "$SCRIPT_DIR/lib/connectivity.sh"

DRY_RUN=false
FRESH=false
DEBUG=false
NONINTERACTIVE=false
SKIP_DOCKER_INSTALL=false
CLI_PORT=""
CLI_EXTERNAL_URL=""
CLI_SSL_MODE=""
CLI_IMAGE=""
CLI_ENV_FILE=""

SSL_MODE=""
PORT=""
EXTERNAL_URL=""
CLIENT_NAME=""

usage() {
    cat <<EOF
Usage: $0 [install|upgrade|uninstall|status|register-webhook|help] [options]

  install                   Run the interactive installer (default)
  upgrade                   Rebuild/pull and restart the app container
  uninstall                 Stop and remove containers/volumes
  status                    Show install state and container status
  register-webhook          (Re-)register the webhook with Eka Care only
  help                      Show this help

Options:
  --dry-run                 Print planned actions without executing them
  --fresh                   Ignore saved step state, start over
  --debug                   Verbose output (set -x, no curl silencing)
  --non-interactive         Never prompt; fail if a required value is missing
  --skip-docker-install     Assume Docker/compose are already installed
  --env-file PATH            Path to the env file (default: config-local.env,
                              materialized from config-local.env.example if missing)
  --port PORT
  --external-url URL
  --ssl-mode managed|external
  --image REF                Use a pre-built image instead of building locally
  -h, --help                 Show this help
EOF
}

log() { echo "[eka-deploy] $*"; }
debug() { $DEBUG && echo "[debug] $*" >&2; true; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required but not installed." >&2; exit 1; }; }
# Random hex string straight from the kernel's CSPRNG - no openssl (or any
# other external binary) needed just to generate a signing key.
random_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt-get"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    fi
}

# Package name for a missing binary, per package manager - centralizes the
# apt/dnf/yum/zypper naming differences so callers just list binaries.
pkg_name_for() {
    local bin="$1" mgr="$2"
    case "$bin:$mgr" in
        curl:*|jq:*|iptables:*) echo "$bin" ;;
        newuidmap:apt-get) echo "uidmap" ;;
        newuidmap:dnf|newuidmap:yum) echo "shadow-utils" ;;
        newuidmap:zypper) echo "shadow" ;;
    esac
}

# Checks the given binaries; if any are missing, detects the host's package
# manager and offers to install the right packages for it (sudo confirmation,
# respects --dry-run/--non-interactive). No-ops with zero prompts if
# everything's already present. Used both for baseline tools (curl, jq) and
# for rootless Docker's own prerequisites (iptables, newuidmap).
ensure_installed() {
    local purpose="$1"; shift
    local missing_bins=() bin
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 || missing_bins+=("$bin")
    done
    [ "${#missing_bins[@]}" -eq 0 ] && return 0

    local mgr
    mgr=$(detect_pkg_manager)
    if [ -z "$mgr" ]; then
        log "Warning: missing ${missing_bins[*]} for $purpose, and no known package manager (apt-get/dnf/yum/zypper) detected."
        log "Install these manually before continuing."
        return 0
    fi

    local pkgs=()
    for bin in "${missing_bins[@]}"; do
        pkgs+=("$(pkg_name_for "$bin" "$mgr")")
    done

    local install_cmd
    case "$mgr" in
        apt-get) install_cmd="sudo apt-get update && sudo apt-get install -y ${pkgs[*]}" ;;
        dnf)     install_cmd="sudo dnf install -y ${pkgs[*]}" ;;
        yum)     install_cmd="sudo yum install -y ${pkgs[*]}" ;;
        zypper)  install_cmd="sudo zypper install -y ${pkgs[*]}" ;;
    esac

    log "$purpose needs: ${missing_bins[*]} (missing). Package(s) to install via $mgr: ${pkgs[*]}"
    if ! $NONINTERACTIVE; then
        read -r -p "Install missing prerequisites (${pkgs[*]}) via sudo $mgr now? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborting: $purpose requires ${missing_bins[*]}."; exit 1; }
    fi
    if $DRY_RUN; then
        echo "[dry-run] would run: $install_cmd"
    else
        eval "$install_cmd"
    fi
}

# Ensures a kernel module is loaded - rootless Docker's setup script checks
# for nf_tables itself and refuses to proceed on minimal images (e.g. Amazon
# Linux 2023) where nothing's triggered netfilter yet, even once iptables-nft
# is installed. No-ops with zero prompts if already loaded. Also persists it
# via modules-load.d so a reboot doesn't reintroduce the gap.
ensure_kernel_module() {
    local module="$1"
    lsmod 2>/dev/null | grep -q "^${module}[[:space:]]" && return 0

    log "Kernel module '$module' is not loaded (required for rootless Docker's iptables/nftables setup)."
    if ! $NONINTERACTIVE; then
        read -r -p "Load kernel module '$module' now via sudo modprobe? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborting: rootless Docker requires the '$module' kernel module."; exit 1; }
    fi
    if $DRY_RUN; then
        echo "[dry-run] would run: sudo modprobe $module"
        echo "[dry-run] would run: echo $module | sudo tee /etc/modules-load.d/eka-docker.conf"
    else
        sudo modprobe "$module"
        echo "$module" | sudo tee /etc/modules-load.d/eka-docker.conf >/dev/null
    fi
}

# ---- CLI parsing ----------------------------------------------------------

ACTION="install"
if [[ $# -gt 0 ]]; then
    case "$1" in
        install|upgrade|uninstall|status|register-webhook|help) ACTION="$1"; shift ;;
        -h|--help) usage; exit 0 ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --fresh) FRESH=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --non-interactive) NONINTERACTIVE=true; shift ;;
        --skip-docker-install) SKIP_DOCKER_INSTALL=true; shift ;;
        --env-file) CLI_ENV_FILE="$2"; shift 2 ;;
        --port) CLI_PORT="$2"; shift 2 ;;
        --external-url) CLI_EXTERNAL_URL="$2"; shift 2 ;;
        --ssl-mode) CLI_SSL_MODE="$2"; shift 2 ;;
        --image) CLI_IMAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; usage; exit 1 ;;
    esac
done

[ "$ACTION" == "help" ] && { usage; exit 0; }
[ -n "$CLI_ENV_FILE" ] && CONFIG_FILE="$CLI_ENV_FILE"

$DEBUG && set -x
ensure_installed "deploy-local.sh" curl jq

# ---- state file (~/.eka-deploy/state.json) --------------------------------
# Tracks step completion only. Actual answers/secrets live in config-local.env
# (the single source of truth), never duplicated here.

state_init() {
    $DRY_RUN && return 0
    mkdir -p "$STATE_DIR"
    if $FRESH || [ ! -f "$STATE_FILE" ]; then
        printf '{"version":1,"updated_at":"","config_file":"%s","steps":{}}' "$CONFIG_FILE" > "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi
}

state_step_status() { jq -r --arg s "$1" '.steps[$s] // "pending"' "$STATE_FILE" 2>/dev/null || echo "pending"; }

state_mark_done() {
    $DRY_RUN && return 0
    local tmp
    tmp=$(mktemp)
    jq --arg s "$1" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.steps[$s]="done" | .updated_at=$t' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

step_done() { [ "$(state_step_status "$1")" == "done" ]; }

# ---- config-local.env helpers ----------------------------------------------

set_env_var() {
    local file="$1" key="$2" value="$3"
    if $DRY_RUN; then
        echo "[dry-run] would set ${key} in $(basename "$file")"
        return 0
    fi
    local escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# ask PROMPT VARNAME DEFAULT SECRET REQUIRED
# Skips prompting entirely if $VARNAME is already non-empty - this is what
# makes re-runs idempotent (only missing/invalid values get re-asked).
ask() {
    local prompt="$1" varname="$2" default="${3:-}" secret="${4:-false}" required="${5:-false}"
    local current="${!varname:-}"
    if [ -n "$current" ]; then return 0; fi

    if $NONINTERACTIVE; then
        if [ -n "$default" ]; then printf -v "$varname" '%s' "$default"; return 0; fi
        if [ "$required" == "true" ]; then
            echo "Error: $varname is required but not set. Pre-fill it in $CONFIG_FILE or pass it as a flag." >&2
            exit 1
        fi
        printf -v "$varname" '%s' ""
        return 0
    fi

    local answer
    while true; do
        if [ "$secret" == "true" ]; then
            read -r -s -p "$prompt: " answer; echo
        elif [ -n "$default" ]; then
            read -r -p "$prompt [$default]: " answer
            answer="${answer:-$default}"
        else
            read -r -p "$prompt: " answer
        fi
        if [ -n "$answer" ] || [ "$required" != "true" ]; then break; fi
        echo "This value is required."
    done
    printf -v "$varname" '%s' "$answer"
}

# ---- network / connectivity helpers ---------------------------------------
# check_tcp / check_connectivity live in lib/connectivity.sh (shared with
# deploy-aws.sh).

parse_registry_host() {
    local ref="$1" first_segment="${1%%/*}"
    if [[ "$first_segment" == *"."* || "$first_segment" == *":"* || "$first_segment" == "localhost" ]]; then
        echo "$first_segment"
    else
        echo "registry-1.docker.io"
    fi
}

dns_sanity_check() {
    local domain="$1"
    command -v dig >/dev/null 2>&1 || { log "dig not installed, skipping DNS sanity check for $domain"; return 0; }
    local resolved public_ip
    resolved=$(dig +short "$domain" | tail -n1 || true)
    public_ip=$(curl -s --max-time 5 https://checkip.amazonaws.com || true)
    if [ -n "$resolved" ] && [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
        log "Warning: $domain resolves to '$resolved' but this machine's public IP looks like '$public_ip'."
        log "Certbot's HTTP-01 challenge will fail until DNS points $domain here."
    fi
}

# ---- docker compose wrapper -------------------------------------------------
# Single compose file - this wrapper is what decides what runs, not the
# compose file itself: activates the "ssl" profile (nginx + certbot) only
# when SSL_MODE=managed, and pins the app's published bind address to
# 127.0.0.1 in that case (only nginx should be publicly reachable).
# `config` always runs for real - it only renders/validates, never mutates.

compose() {
    local args=(-f "$SCRIPT_DIR/docker-compose.yml")
    if [ "$SSL_MODE" == "managed" ]; then
        args+=(--profile ssl)
        export APP_BIND_ADDR="127.0.0.1"
    else
        export APP_BIND_ADDR="0.0.0.0"
    fi
    if $DRY_RUN && [ "${1:-}" != "config" ]; then
        echo "[dry-run] would run: docker compose ${args[*]} --env-file $CONFIG_FILE $*"
        return 0
    fi
    docker compose "${args[@]}" --env-file "$CONFIG_FILE" "$@"
}

# ---- steps ------------------------------------------------------------------

step_preflight() {
    if step_done "preflight" && ! $FRESH; then log "preflight: already done, skipping"; return; fi
    log "Checking system requirements..."

    if [ "$(uname -s)" != "Linux" ]; then
        echo "Error: deploy-local.sh only supports Linux (bare metal or VM)." >&2
        exit 1
    fi

    local mem_kb mem_gb cpu_count disk_avail_gb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_gb=$((mem_kb / 1024 / 1024))
    cpu_count=$(nproc)
    disk_avail_gb=$(df -Pk "$SCRIPT_DIR" | tail -1 | awk '{print int($4/1024/1024)}')
    log "Machine: ${cpu_count} vCPU, ${mem_gb}GB RAM, ${disk_avail_gb}GB free disk"
    [ "$mem_gb" -lt 1 ] && log "Warning: less than 1GB RAM detected."
    [ "$disk_avail_gb" -lt 2 ] && log "Warning: less than 2GB free disk detected."

    [ -n "$CLI_PORT" ] && PORT="$CLI_PORT"
    ask "Port to expose the webhook service on" PORT "${PORT:-8080}" false true
    set_env_var "$CONFIG_FILE" PORT "$PORT"
    if ! $DRY_RUN && command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -q ":${PORT}\$"; then
        echo "Error: port $PORT is already in use on this host." >&2
        exit 1
    fi

    log "Checking outbound connectivity (client firewalls commonly block some of these)..."
    local conn_failed=0
    check_connectivity "www.eka.care" 443 "Eka Care" || conn_failed=1
    check_connectivity "api.eka.care" 443 "Eka Care API (webhook registration)" || conn_failed=1

    local registry_host
    registry_host=$(parse_registry_host "${CLI_IMAGE:-registry-1.docker.io/library/python}")
    check_connectivity "$registry_host" 443 "Docker registry (app image)" || conn_failed=1

    if ! $SKIP_DOCKER_INSTALL && ! (command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1); then
        check_connectivity "get.docker.com" 443 "Docker install script" || conn_failed=1
    fi

    local known_ssl_mode="${CLI_SSL_MODE:-$SSL_MODE}"
    if [ "$known_ssl_mode" == "managed" ]; then
        # nginx/certbot images are always pulled from Docker Hub, regardless
        # of --image pointing the app at a different (private) registry.
        if [ "$registry_host" != "registry-1.docker.io" ]; then
            check_connectivity "registry-1.docker.io" 443 "Docker Hub (nginx/certbot images)" || conn_failed=1
        fi
        check_connectivity "acme-v02.api.letsencrypt.org" 443 "Let's Encrypt" || conn_failed=1
        # Advisory only - only used for the best-effort DNS sanity warning
        # later, so its unreachability never blocks the install.
        if command -v dig >/dev/null 2>&1; then
            check_connectivity "checkip.amazonaws.com" 443 "Public IP lookup (DNS sanity check)" ||
                log "  (non-fatal) DNS sanity check will be skipped without this."
        fi
    fi

    if [ "$conn_failed" -eq 1 ]; then
        echo "Error: one or more required endpoints are unreachable (see FAIL lines above)." >&2
        echo "Ask your network/security team to allow outbound HTTPS to them, then re-run install." >&2
        exit 1
    fi

    state_mark_done "preflight"
}

step_docker_install() {
    if step_done "docker_install" && ! $FRESH; then log "docker_install: already done, skipping"; return; fi

    if $SKIP_DOCKER_INSTALL; then
        log "docker_install: --skip-docker-install given, verifying docker is present"
        require_cmd docker
        docker compose version >/dev/null 2>&1 || { echo "Error: docker compose plugin not found." >&2; exit 1; }
        state_mark_done "docker_install"
        return
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker + compose already installed"
    else
        if ! $NONINTERACTIVE; then
            read -r -p "Docker/compose not found. Install rootless Docker now? [y/N]: " CONFIRM
            [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborting: Docker is required (or re-run with --skip-docker-install once installed)."; exit 1; }
        fi
        ensure_installed "rootless Docker" iptables newuidmap
        ensure_kernel_module nf_tables

        if $DRY_RUN; then
            echo "[dry-run] would run: curl -fsSL https://get.docker.com/rootless | sh"
            echo "[dry-run] would run: systemctl --user enable --now docker"
            echo "[dry-run] would run: loginctl enable-linger \$(whoami)"
        else
            curl -fsSL https://get.docker.com/rootless | sh
            systemctl --user enable --now docker
            loginctl enable-linger "$(whoami)"
            export PATH="$HOME/bin:$PATH"
            export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
        fi
    fi

    local known_ssl_mode="${CLI_SSL_MODE:-$SSL_MODE}"
    if [ "$known_ssl_mode" == "managed" ]; then
        HTTP_PORT="${HTTP_PORT:-80}"
        HTTPS_PORT="${HTTPS_PORT:-443}"
        local min_port="$HTTP_PORT"
        [ "$HTTPS_PORT" -lt "$min_port" ] && min_port="$HTTPS_PORT"

        local start_port
        start_port=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
        if [ "$start_port" -gt "$min_port" ]; then
            log "Ports $HTTP_PORT/$HTTPS_PORT need net.ipv4.ip_unprivileged_port_start=$min_port for rootless Docker to bind them."
            if ! $NONINTERACTIVE; then
                read -r -p "Apply this via sudo now (writes /etc/sysctl.d/90-eka-rootless-ports.conf)? [y/N]: " CONFIRM
                [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborting: cannot bind privileged ports without this."; exit 1; }
            fi
            if $DRY_RUN; then
                echo "[dry-run] would run: sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=$min_port > /etc/sysctl.d/90-eka-rootless-ports.conf && sysctl --system'"
            else
                sudo sh -c "echo net.ipv4.ip_unprivileged_port_start=$min_port > /etc/sysctl.d/90-eka-rootless-ports.conf && sysctl --system"
            fi
        fi
    fi

    state_mark_done "docker_install"
}

step_network_create() {
    if step_done "network_create" && ! $FRESH; then log "network_create: already done, skipping"; return; fi
    if $DRY_RUN; then
        echo "[dry-run] would run: docker network create eka-net (if missing)"
    else
        docker network inspect eka-net >/dev/null 2>&1 || docker network create eka-net
    fi
    state_mark_done "network_create"
}

step_ssl_setup() {
    if step_done "ssl_setup" && ! $FRESH; then log "ssl_setup: already done, skipping"; return; fi

    [ -n "$CLI_EXTERNAL_URL" ] && EXTERNAL_URL="$CLI_EXTERNAL_URL"
    ask "External URL clients will reach this service on (e.g. https://webhook.example.com)" EXTERNAL_URL "" false true
    set_env_var "$CONFIG_FILE" EXTERNAL_URL "$EXTERNAL_URL"

    [ -n "$CLI_SSL_MODE" ] && SSL_MODE="$CLI_SSL_MODE"
    ask "Manage SSL for you via nginx+certbot, or do you already terminate TLS yourself? [managed/external]" SSL_MODE "external" false true
    set_env_var "$CONFIG_FILE" SSL_MODE "$SSL_MODE"

    if [ "$SSL_MODE" == "managed" ]; then
        local domain
        domain=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
        dns_sanity_check "$domain"

        HTTP_PORT="${HTTP_PORT:-80}"
        HTTPS_PORT="${HTTPS_PORT:-443}"
        set_env_var "$CONFIG_FILE" HTTP_PORT "$HTTP_PORT"
        set_env_var "$CONFIG_FILE" HTTPS_PORT "$HTTPS_PORT"
        if [ "$HTTP_PORT" != "80" ]; then
            log "Warning: HTTP_PORT=$HTTP_PORT (not 80). Let's Encrypt's HTTP-01 challenge always"
            log "connects on the public port 80, so something else must forward port 80 to $HTTP_PORT"
            log "on this host, or certificate issuance will fail."
        fi

        if $DRY_RUN; then
            echo "[dry-run] would render nginx/nginx.conf (bootstrap, HTTP-only) for domain $domain"
        else
            mkdir -p "$SCRIPT_DIR/nginx/ssl-enabled"
            EXTERNAL_DOMAIN="$domain" PORT="$PORT" HTTP_PORT="$HTTP_PORT" \
                envsubst '${EXTERNAL_DOMAIN} ${PORT} ${HTTP_PORT}' \
                < "$SCRIPT_DIR/nginx/nginx.conf.example" > "$SCRIPT_DIR/nginx/nginx.conf"
        fi
    fi

    state_mark_done "ssl_setup"
}

step_generate_env() {
    if step_done "generate_env" && ! $FRESH; then log "generate_env: already done, skipping"; return; fi

    ask "Client integration to use (metropolis/miracles)" CLIENT_NAME "metropolis" false true
    set_env_var "$CONFIG_FILE" CLIENT_NAME "$CLIENT_NAME"

    [ "${CLIENT_ID:-}" == "YOUR_CLIENT_ID" ] && CLIENT_ID=""
    ask "Client ID" CLIENT_ID "" false true
    set_env_var "$CONFIG_FILE" CLIENT_ID "$CLIENT_ID"

    [ "${CLIENT_SECRET:-}" == "YOUR_CLIENT_SECRET" ] && CLIENT_SECRET=""
    ask "Client Secret" CLIENT_SECRET "" true true
    set_env_var "$CONFIG_FILE" CLIENT_SECRET "$CLIENT_SECRET"

    [ "${API_KEY:-}" == "YOUR_API_KEY" ] && API_KEY=""
    ask "API Key" API_KEY "" true true
    set_env_var "$CONFIG_FILE" API_KEY "$API_KEY"

    if [ -z "${SIGNING_KEY:-}" ]; then
        if $NONINTERACTIVE; then
            SIGNING_KEY=$(random_hex 16)
            log "Generated SIGNING_KEY"
        else
            read -r -p "Signing Key (leave blank to auto-generate): " SIGNING_KEY
            if [ -z "$SIGNING_KEY" ]; then
                SIGNING_KEY=$(random_hex 16)
                log "Generated SIGNING_KEY"
            fi
        fi
    fi
    set_env_var "$CONFIG_FILE" SIGNING_KEY "$SIGNING_KEY"

    if [ "$CLIENT_NAME" == "metropolis" ]; then
        [ "${YELLOW_AI_API_KEY:-}" == "YOUR_YELLOW_AI_API_KEY" ] && YELLOW_AI_API_KEY=""
        ask "Yellow.ai API Key" YELLOW_AI_API_KEY "" true false
        set_env_var "$CONFIG_FILE" YELLOW_AI_API_KEY "$YELLOW_AI_API_KEY"

        [ "${JAPI_KEY:-}" == "YOUR_JAPI_KEY" ] && JAPI_KEY=""
        ask "JAPI Key" JAPI_KEY "" true false
        set_env_var "$CONFIG_FILE" JAPI_KEY "$JAPI_KEY"

        [ "${JAPI_AUTHORIZATION:-}" == "YOUR_JAPI_AUTHORIZATION" ] && JAPI_AUTHORIZATION=""
        ask "JAPI Authorization" JAPI_AUTHORIZATION "" true false
        set_env_var "$CONFIG_FILE" JAPI_AUTHORIZATION "$JAPI_AUTHORIZATION"
    fi

    $DRY_RUN || chmod 600 "$CONFIG_FILE"
    state_mark_done "generate_env"
}

step_config_validate() {
    if step_done "config_validate" && ! $FRESH; then log "config_validate: already done, skipping"; return; fi
    log "Validating rendered compose configuration..."
    if $DRY_RUN && ! command -v docker >/dev/null 2>&1; then
        echo "[dry-run] docker isn't installed yet - skipping live 'compose config' validation"
        state_mark_done "config_validate"
        return
    fi
    compose config -q || { echo "Error: compose config validation failed - fix config-local.env and retry." >&2; exit 1; }
    state_mark_done "config_validate"
}

step_build_and_start() {
    if step_done "build_and_start" && ! $FRESH; then log "build_and_start: already done, skipping"; return; fi

    if [ -n "$CLI_IMAGE" ]; then
        export APP_IMAGE="$CLI_IMAGE"
        log "Using pre-built image $CLI_IMAGE (skipping local build)"
    else
        compose build app
    fi

    if ! compose up -d; then
        echo "Start failed, reverting (docker compose down)..." >&2
        compose down || true
        exit 1
    fi

    if [ "$SSL_MODE" == "managed" ] && [ ! -f "$SCRIPT_DIR/nginx/ssl-enabled/nginx-https.conf" ]; then
        local domain
        domain=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
        log "Requesting a Let's Encrypt certificate for $domain..."
        if $DRY_RUN; then
            echo "[dry-run] would run: certbot certonly --webroot -w /var/www/certbot -d $domain"
            echo "[dry-run] would render nginx/ssl-enabled/nginx-https.conf and reload nginx"
        else
            if ! compose run --rm certbot certonly --webroot -w /var/www/certbot \
                -d "$domain" --non-interactive --agree-tos -m "admin@${domain}" --no-eff-email; then
                echo "Error: certificate issuance failed. Check DNS points $domain at this host, then retry with 'install'." >&2
                compose down || true
                exit 1
            fi
            EXTERNAL_DOMAIN="$domain" PORT="$PORT" HTTPS_PORT="${HTTPS_PORT:-443}" \
                envsubst '${EXTERNAL_DOMAIN} ${PORT} ${HTTPS_PORT}' \
                < "$SCRIPT_DIR/nginx/nginx-https.conf.example" > "$SCRIPT_DIR/nginx/ssl-enabled/nginx-https.conf"
            compose exec nginx nginx -s reload
        fi
    fi

    state_mark_done "build_and_start"
}

step_health_check() {
    if step_done "health_check" && ! $FRESH; then log "health_check: already done, skipping"; return; fi
    if $DRY_RUN; then
        echo "[dry-run] would poll http://127.0.0.1:${PORT}/ for readiness"
        state_mark_done "health_check"
        return
    fi

    local attempt=0 max=15
    until curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -q '404'; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max" ]; then
            echo "Error: app did not become healthy on port $PORT after $max attempts." >&2
            exit 1
        fi
        sleep 2
    done
    log "App is up on port $PORT"

    if [ "$SSL_MODE" == "managed" ]; then
        local domain check_url
        domain=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
        check_url="https://${domain}:${HTTPS_PORT:-443}/"
        curl -sf -o /dev/null "$check_url" \
            || log "Warning: $check_url not reachable yet (DNS/cert propagation can take a few minutes)."
    fi
    state_mark_done "health_check"
}

step_webhook_register() {
    if step_done "webhook_register" && ! $FRESH; then log "webhook_register: already done, skipping"; return; fi
    if $DRY_RUN; then
        echo "[dry-run] would call register_webhook() (POST to api.eka.care)"
        state_mark_done "webhook_register"
        return
    fi

    set -a; source "$CONFIG_FILE"; set +a

    local attempt=0 max=5 delay=5
    until register_webhook; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max" ]; then
            echo "Error: webhook registration failed after $max attempts." >&2
            echo "Fix the reported issue, then re-run: $0 register-webhook" >&2
            exit 1
        fi
        log "Retrying webhook registration in ${delay}s (attempt $((attempt + 1))/$max)..."
        sleep "$delay"
        delay=$((delay * 2))
    done
    state_mark_done "webhook_register"
}

step_finalize() {
    log "Deployment complete."
    echo "  URL:          ${EXTERNAL_URL:-http://<this-host>:${PORT}}"
    if [ "$SSL_MODE" == "managed" ] && [ "${HTTPS_PORT:-443}" != "443" ]; then
        echo "                (nginx is listening on non-standard HTTPS_PORT=$HTTPS_PORT - include it in the URL: ${EXTERNAL_URL}:${HTTPS_PORT})"
    fi
    echo "  Config file:  $CONFIG_FILE"
    local profile_flag=""
    [ "$SSL_MODE" == "managed" ] && profile_flag="--profile ssl "
    echo "  View logs:    $0 status   (or) docker compose --env-file $CONFIG_FILE -f docker-compose.yml ${profile_flag}logs -f app"
    echo "  Upgrade:      $0 upgrade [--image <ref>]"
    echo "  Uninstall:    $0 uninstall"
}

# ---- subcommands -------------------------------------------------------------

load_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        local example="${CONFIG_FILE}.example"
        [ -f "$example" ] || { echo "Error: neither $CONFIG_FILE nor $example found." >&2; exit 1; }
        if $DRY_RUN; then
            echo "[dry-run] would create $CONFIG_FILE from $(basename "$example")"
        else
            cp "$example" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            log "Created $(basename "$CONFIG_FILE") from $(basename "$example")"
        fi
    fi
    set -a
    # shellcheck source=config-local.env
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    set +a
}

# Runs before anything else on install/upgrade: confirms the files this
# installer depends on are present and the env/nginx config is structurally
# sound, so a broken or incomplete checkout fails immediately with a clear
# message instead of partway through the install.
verify_setup() {
    log "Verifying installer files and configuration..."
    local missing=0 f
    local required_files=(
        "$SCRIPT_DIR/docker-compose.yml"
        "$SCRIPT_DIR/Dockerfile"
        "$SCRIPT_DIR/nginx/nginx.conf.example"
        "$SCRIPT_DIR/nginx/nginx-https.conf.example"
    )
    for f in "${required_files[@]}"; do
        if [ -f "$f" ]; then
            log "  OK       ${f#"$SCRIPT_DIR"/}"
        else
            log "  MISSING  ${f#"$SCRIPT_DIR"/}"
            missing=1
        fi
    done

    load_config_file
    if [ -f "$CONFIG_FILE" ]; then
        log "  OK       $(basename "$CONFIG_FILE")"
    elif $DRY_RUN && [ -f "${CONFIG_FILE}.example" ]; then
        log "  OK       $(basename "$CONFIG_FILE") (dry-run: would be created from .example)"
    else
        log "  MISSING  $(basename "$CONFIG_FILE")"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo "Error: this checkout is missing files the installer depends on - re-clone/restore the repo before continuing." >&2
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log "  (dry-run) compose config validation skipped - $(basename "$CONFIG_FILE") doesn't exist yet"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        SSL_MODE="${CLI_SSL_MODE:-${SSL_MODE:-external}}"
        local err_log
        err_log=$(mktemp)
        if compose config -q 2>"$err_log"; then
            log "  OK       docker-compose.yml + $(basename "$CONFIG_FILE") render correctly"
        else
            echo "Error: docker-compose.yml / $(basename "$CONFIG_FILE") failed to validate:" >&2
            cat "$err_log" >&2
            rm -f "$err_log"
            exit 1
        fi
        rm -f "$err_log"
    else
        log "  Docker not installed yet - full compose config validation runs later (config_validate step)"
    fi
}

cmd_install() {
    verify_setup
    state_init
    step_preflight
    step_docker_install
    step_network_create
    step_ssl_setup
    step_generate_env
    step_config_validate
    step_build_and_start
    step_health_check
    step_webhook_register
    step_finalize
}

cmd_upgrade() {
    verify_setup
    state_init
    [ -n "$CLI_IMAGE" ] && export APP_IMAGE="$CLI_IMAGE"
    if [ -z "$CLI_IMAGE" ]; then
        compose build app
    fi
    compose up -d
    step_health_check
    log "Upgrade complete."
}

cmd_uninstall() {
    load_config_file
    if ! $NONINTERACTIVE; then
        read -r -p "This stops and removes eka-webhook containers and named volumes. Continue? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    compose down -v
    if ! $NONINTERACTIVE; then
        read -r -p "Also remove the docker network 'eka-net'? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            docker network rm eka-net 2>/dev/null || true
        fi
    fi
    echo "Note: $CONFIG_FILE and $STATE_FILE were left in place (they hold secrets/history) - remove manually if no longer needed."
}

cmd_status() {
    if [ -f "$STATE_FILE" ]; then
        echo "Install state ($STATE_FILE):"
        jq '.' "$STATE_FILE"
    else
        echo "No install state found at $STATE_FILE (nothing installed yet?)"
    fi
    echo
    if [ -f "$CONFIG_FILE" ]; then
        load_config_file
        compose ps 2>/dev/null || true
    fi
}

cmd_register_webhook() {
    load_config_file
    register_webhook
}

case "$ACTION" in
    install) cmd_install ;;
    upgrade) cmd_upgrade ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    register-webhook) cmd_register_webhook ;;
    *) usage; exit 1 ;;
esac
