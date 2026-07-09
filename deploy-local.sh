#!/bin/bash
# Interactive installer for the eka-webhook service on bare metal / VM / local
# Linux hosts (no AWS dependency). See docs/bare-metal.md for full documentation.
#
# Usage: ./deploy-local.sh [install|upgrade|uninstall|status|register-webhook|help] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
STATE_DIR="$HOME/.eka-deploy"
STATE_FILE="$STATE_DIR/state.json"

# get.docker.com/rootless always installs to ~/bin, and sets it as the
# default CLI context so DOCKER_HOST isn't strictly required for routing -
# but this script itself is a non-interactive shell (invoked as
# ./deploy-local.sh), so it never sources ~/.bashrc the way an interactive
# login shell does. A previously-installed rootless Docker would otherwise
# look "not found" here (command -v only checks $PATH as inherited from the
# invoking shell) even though it's fine - so check the well-known install
# location directly rather than trusting whatever PATH we happened to
# inherit.
[ -d "$HOME/bin" ] && PATH="$HOME/bin:$PATH"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" ]; then
    export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
fi

# shellcheck source=lib/register-webhook.sh
source "$SCRIPT_DIR/lib/register-webhook.sh"
# shellcheck source=lib/connectivity.sh
source "$SCRIPT_DIR/lib/connectivity.sh"

DRY_RUN=false
FRESH=false
DEBUG=false
NONINTERACTIVE=false
SKIP_DOCKER_INSTALL=false
# Set true once the user confirms an existing config.env is fine as-is
# (see confirm_existing_config()) - suppresses ask()'s per-field "existing:
# ..., Enter to keep" walkthrough for already-set values, WITHOUT touching
# NONINTERACTIVE (which also gates sudo confirmations for system changes -
# those must still be asked regardless of this).
CONFIG_CONFIRMED=false
# Space-separated, UPPERCASE list of field names the user explicitly asked
# to change (see confirm_existing_config()) when they didn't want the whole
# file as-is but also didn't want to walk every field one by one. Empty
# means "no specific list" - normal per-field behavior applies.
FIELDS_TO_CHANGE=""

field_should_prompt() {
    case " $FIELDS_TO_CHANGE " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
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
Usage: $0 [install|upgrade|stop|uninstall|status|register-webhook|help] [options]

  install                   Run the interactive installer (default)
  upgrade                   Rebuild/pull and restart the app container
  stop                      Stop and remove containers only (keeps config/volumes/certs)
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
  --env-file PATH            Path to the env file (default: config.env,
                              materialized from config.env.example if missing)
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

# Set true once the user answers "a"/"A" ("yes to all") at any confirm()
# prompt - every confirm() call for the rest of this run is then answered
# yes automatically, same "a" convention many Linux installers use, so a
# multi-step install doesn't need "y" typed a dozen separate times.
CONFIRM_ALL=false

# Prompts a y/N/a confirmation. Returns 0 (confirmed) or 1 (declined) -
# never actually prompts once CONFIRM_ALL is set. Callers are still
# responsible for checking $NONINTERACTIVE themselves before calling this
# (matches every existing call site's structure).
confirm() {
    local prompt="$1"
    $CONFIRM_ALL && return 0
    local answer
    read -r -p "$prompt [y/N/a]: " answer
    case "$answer" in
        [Aa]) CONFIRM_ALL=true; return 0 ;;
        [Yy]) return 0 ;;
        *) return 1 ;;
    esac
}
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
        confirm "Install missing prerequisites (${pkgs[*]}) via sudo $mgr now?" || { echo "Aborting: $purpose requires ${missing_bins[*]}."; exit 1; }
    fi
    if $DRY_RUN; then
        echo "[dry-run] would run: $install_cmd"
    else
        eval "$install_cmd"
    fi
}

# Ensures kernel modules are loaded - rootless Docker's setup script checks
# for nf_tables (nftables backend) and/or ip_tables (legacy iptables
# backend), depending on which one the host's iptables actually uses, and
# refuses to proceed on minimal images (e.g. Amazon Linux 2023's nf_tables,
# Ubuntu's ip_tables when on the legacy backend) where nothing's triggered
# netfilter yet. Takes multiple module names and asks once for all of them
# missing, rather than a separate sudo prompt per module. No-ops with zero
# prompts if everything's already loaded. Persists them via modules-load.d
# so a reboot doesn't reintroduce the gap.
ensure_kernel_modules() {
    local missing=() mod
    for mod in "$@"; do
        lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]" || missing+=("$mod")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    log "Kernel module(s) not loaded (required for rootless Docker's iptables/nftables setup): ${missing[*]}"
    if ! $NONINTERACTIVE; then
        confirm "Load ${missing[*]} now via sudo modprobe?" || { echo "Aborting: rootless Docker requires: ${missing[*]}."; exit 1; }
    fi
    if $DRY_RUN; then
        echo "[dry-run] would run: sudo modprobe ${missing[*]}"
        echo "[dry-run] would run: printf '%s\\n' ${missing[*]} | sudo tee /etc/modules-load.d/eka-docker.conf"
    else
        sudo modprobe "${missing[@]}"
        printf '%s\n' "${missing[@]}" | sudo tee /etc/modules-load.d/eka-docker.conf >/dev/null
    fi
}

# get.docker.com/rootless extracts the dockerd binary to ~/bin *before*
# running its own prereq checks (e.g. the nf_tables one above). If an earlier
# run died after that extraction but before finishing, the installer sees
# the leftover binary on retry, refuses to do anything, and just prints
# manual cleanup instructions - leaving Docker not actually installed. Detect
# that exact leftover and clean it up automatically instead of failing again.
ensure_clean_rootless_install() {
    local dockerd_bin="$HOME/bin/dockerd"
    [ -e "$dockerd_bin" ] || return 0

    log "Found a leftover rootless Docker binary at $dockerd_bin from a previous incomplete install."
    if ! $NONINTERACTIVE; then
        confirm "Remove it and retry installation?" || { echo "Aborting: remove $dockerd_bin manually (after 'systemctl --user stop docker') and re-run, or pass --skip-docker-install if Docker is already usable."; exit 1; }
    fi
    if $DRY_RUN; then
        echo "[dry-run] would run: systemctl --user stop docker (best-effort)"
        echo "[dry-run] would run: rm -f $dockerd_bin"
    else
        systemctl --user stop docker 2>/dev/null || true
        rm -f "$dockerd_bin"
    fi
}

# Ubuntu 23.10+/24.04+ restricts unprivileged user namespaces via AppArmor by
# default (kernel.apparmor_restrict_unprivileged_userns=1). rootlesskit's
# re-exec of /proc/self/exe to set up the userns then fails with "permission
# denied", and dockerd-rootless-setuptool.sh has no automated recovery for
# it. Pre-install the exact AppArmor profile Docker's own error message
# recommends - scoped to this user's rootlesskit path - before attempting
# the install, instead of failing partway through it. The profile doesn't
# need rootlesskit to already exist at that path; AppArmor just won't do
# anything with the rule until a process actually runs from there.
ensure_apparmor_userns_allowed() {
    local restrict_file="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    [ -f "$restrict_file" ] || return 0
    [ "$(cat "$restrict_file" 2>/dev/null)" == "1" ] || return 0
    command -v apparmor_parser >/dev/null 2>&1 || return 0

    local rootlesskit_bin="$HOME/bin/rootlesskit"
    local profile_name profile_path
    profile_name="$(echo "$rootlesskit_bin" | sed -e 's#^/##' -e 's#/#.#g')"
    profile_path="/etc/apparmor.d/$profile_name"
    [ -f "$profile_path" ] && return 0

    log "AppArmor is restricting unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=1) - rootless Docker's rootlesskit needs an exemption, or it fails with 'permission denied'."
    if ! $NONINTERACTIVE; then
        confirm "Install an AppArmor profile allowing rootlesskit ($rootlesskit_bin) unconfined userns access, via sudo?" || { echo "Aborting: rootless Docker cannot start without this. See https://rootlesscontaine.rs/getting-started/common/"; exit 1; }
    fi

    if $DRY_RUN; then
        echo "[dry-run] would write $profile_path and run: sudo systemctl restart apparmor.service"
    else
        cat <<EOF | sudo tee "$profile_path" >/dev/null
abi <abi/4.0>,
include <tunables/global>

$rootlesskit_bin flags=(unconfined) {
  userns,

  include if exists <local/$profile_name>
}
EOF
        sudo systemctl restart apparmor.service
    fi
}

# get.docker.com/rootless installs core Docker (dockerd/docker/containerd/runc)
# but NOT the Compose CLI plugin - "docker compose" comes back as "unknown
# command" until this is installed separately, regardless of whether Docker
# itself was just freshly installed or was already present on the box.
# No-ops with zero prompts if it's already working.
ensure_compose_plugin() {
    if ! docker compose version >/dev/null 2>&1; then
        log "Docker Compose CLI plugin not found ('docker compose' is unrecognized)."
        if ! $NONINTERACTIVE; then
            confirm "Download and install it now (to ~/.docker/cli-plugins/docker-compose)?" || { echo "Aborting: the Docker Compose plugin is required."; exit 1; }
        fi

        local arch compose_url
        arch=$(uname -m)
        case "$arch" in
            x86_64)  compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" ;;
            aarch64) compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64" ;;
            *) echo "Error: no known Docker Compose plugin build for architecture '$arch'. Install it manually: https://docs.docker.com/compose/install/linux/#install-the-plugin-manually" >&2; exit 1 ;;
        esac

        if $DRY_RUN; then
            echo "[dry-run] would run: mkdir -p ~/.docker/cli-plugins && curl -fsSL $compose_url -o ~/.docker/cli-plugins/docker-compose && chmod +x ~/.docker/cli-plugins/docker-compose"
        else
            mkdir -p "$HOME/.docker/cli-plugins"
            curl -fsSL "$compose_url" -o "$HOME/.docker/cli-plugins/docker-compose" || {
                echo "Error: failed to download the Docker Compose plugin from $compose_url" >&2
                exit 1
            }
            chmod +x "$HOME/.docker/cli-plugins/docker-compose"
            docker compose version >/dev/null 2>&1 || {
                echo "Error: Docker Compose plugin installed but 'docker compose version' still fails." >&2
                exit 1
            }
        fi
    fi

    # Some tooling/scripts (and muscle memory) still expect the old
    # standalone `docker-compose` (hyphenated) binary rather than typing
    # `docker compose` (v2 subcommand). We only ever install the v2 plugin -
    # provide a thin forwarding shim so the hyphenated form also works,
    # rather than it just failing with "command not found". No-op if
    # something already provides docker-compose.
    if ! command -v docker-compose >/dev/null 2>&1; then
        if $DRY_RUN; then
            echo "[dry-run] would write a docker-compose -> 'docker compose' shim to $HOME/bin/docker-compose"
        else
            mkdir -p "$HOME/bin"
            cat > "$HOME/bin/docker-compose" <<'SHIM'
#!/bin/sh
exec docker compose "$@"
SHIM
            chmod +x "$HOME/bin/docker-compose"
            log "Added a docker-compose -> 'docker compose' shim at $HOME/bin/docker-compose (for tooling/scripts expecting the old binary name)."
        fi
    fi
}

# Rootless Docker's own installer prints an [INFO] telling you to add PATH/
# DOCKER_HOST to ~/.bashrc yourself - `export`ing them in this script only
# affects this script's own process, so a fresh shell/SSH session would
# still have neither, and "docker"/"docker compose" would just not be found
# until the user did this by hand. Do it for them, idempotently.
persist_rootless_docker_env() {
    local rc_file="$HOME/.bashrc"
    local marker="# Added by eka-webhook deploy-local.sh (rootless Docker)"
    grep -qF "$marker" "$rc_file" 2>/dev/null && return 0

    if $DRY_RUN; then
        echo "[dry-run] would append PATH/DOCKER_HOST exports for rootless Docker to $rc_file"
    else
        {
            echo ""
            echo "$marker"
            echo 'export PATH="$HOME/bin:$PATH"'
            echo 'export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"'
        } >> "$rc_file"
        log "Added rootless Docker's PATH/DOCKER_HOST to $rc_file - open a new shell (or 'source $rc_file') to use 'docker'/'docker compose' directly, without the ~/bin/ prefix."
    fi
}

# ---- CLI parsing ----------------------------------------------------------

ACTION="install"
if [[ $# -gt 0 ]]; then
    case "$1" in
        install|upgrade|stop|uninstall|status|register-webhook|help) ACTION="$1"; shift ;;
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
# Tracks step completion only. Actual answers/secrets live in config.env
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

# ---- config.env helpers ----------------------------------------------

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

# ask PROMPT VARNAME DEFAULT SECRET REQUIRED CONFIRM_EXISTING
# Skips prompting entirely if $VARNAME is already non-empty and CONFIRM_EXISTING
# isn't set - this is what makes re-runs idempotent (only missing/invalid
# values get re-asked). With CONFIRM_EXISTING=true, an existing value is
# surfaced (masked if secret) and kept on a blank Enter, or replaced by typing
# a new one - use this for values worth being visible/overridable across
# re-runs (credentials, keys) instead of silently reusing them with zero
# indication that a saved value exists.
ask() {
    local prompt="$1" varname="$2" default="${3:-}" secret="${4:-false}" required="${5:-false}" confirm_existing="${6:-false}"
    local current="${!varname:-}"

    if [ -n "$current" ]; then
        local want_prompt=false
        if [ -n "$FIELDS_TO_CHANGE" ]; then
            field_should_prompt "$varname" && want_prompt=true
        elif [ "$confirm_existing" == "true" ] && ! $NONINTERACTIVE && ! $CONFIG_CONFIRMED; then
            want_prompt=true
        fi
        $want_prompt || return 0

        local shown="$current" answer
        if [ "$secret" == "true" ]; then
            shown="(hidden)"
            read -r -s -p "$prompt [existing: $shown, Enter to keep]: " answer; echo
        else
            read -r -p "$prompt [existing: $shown, Enter to keep]: " answer
        fi
        [ -n "$answer" ] && printf -v "$varname" '%s' "$answer"
        return 0
    fi

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

    if ! $SKIP_DOCKER_INSTALL; then
        if ! command -v docker >/dev/null 2>&1; then
            check_connectivity "get.docker.com" 443 "Docker install script" || conn_failed=1
        fi
        if ! (command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1); then
            # get.docker.com/rootless doesn't bundle the Compose plugin -
            # ensure_compose_plugin() downloads it from a GitHub release,
            # which redirects to a different CDN host, so both need to be
            # reachable, not just github.com itself.
            check_connectivity "github.com" 443 "Docker Compose plugin download" || conn_failed=1
            check_connectivity "objects.githubusercontent.com" 443 "Docker Compose plugin download (redirect target)" || conn_failed=1
        fi
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
    if step_done "docker_install" && ! $FRESH; then
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            log "docker_install: already done, skipping"
            return
        fi
        log "docker_install: marked done previously, but Docker/Compose isn't fully working now - rechecking"
    fi

    if $SKIP_DOCKER_INSTALL; then
        log "docker_install: --skip-docker-install given, verifying docker is present"
        require_cmd docker
        docker compose version >/dev/null 2>&1 || { echo "Error: docker compose plugin not found." >&2; exit 1; }
        state_mark_done "docker_install"
        return
    fi

    if command -v docker >/dev/null 2>&1; then
        log "Docker already installed"
    else
        if ! $NONINTERACTIVE; then
            confirm "Docker not found. Install rootless Docker now?" || { echo "Aborting: Docker is required (or re-run with --skip-docker-install once installed)."; exit 1; }
        fi
        ensure_installed "rootless Docker" iptables newuidmap
        ensure_kernel_modules nf_tables ip_tables
        ensure_clean_rootless_install
        ensure_apparmor_userns_allowed

        if $DRY_RUN; then
            echo "[dry-run] would run: curl -fsSL https://get.docker.com/rootless | sh"
            echo "[dry-run] would run: systemctl --user enable --now docker"
            echo "[dry-run] would run: sudo loginctl enable-linger \$(whoami)"
        else
            curl -fsSL https://get.docker.com/rootless | sh || {
                echo "Error: rootless Docker install script failed (see output above)." >&2
                exit 1
            }
            if ! systemctl --user list-unit-files docker.service >/dev/null 2>&1; then
                echo "Error: rootless Docker install script did not finish creating the docker.service user unit." >&2
                echo "It may have detected a leftover/partial install and printed manual cleanup steps above - follow those and re-run." >&2
                exit 1
            fi
            systemctl --user enable --now docker
            # Requires root (the installer's own [INFO] says so too - "sudo
            # loginctl enable-linger"). Non-fatal: without it docker.service
            # just won't survive logout/reboot until this is granted, but the
            # daemon is already up for the rest of this run.
            sudo loginctl enable-linger "$(whoami)" || \
                log "Warning: could not enable linger for $(whoami) - docker.service will stop when you log out of this session. Run 'sudo loginctl enable-linger $(whoami)' manually to fix, then 're-login' or reboot."
            export PATH="$HOME/bin:$PATH"
            export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
            persist_rootless_docker_env
        fi
    fi

    ensure_compose_plugin

    state_mark_done "docker_install"
}

# Rootless Docker can't bind ports <1024 unless the kernel allows it (via
# net.ipv4.ip_unprivileged_port_start). Only relevant for managed SSL
# (nginx binds 80/443). This must run in/after step_ssl_setup - SSL_MODE
# isn't known yet in step_docker_install (which runs first), so checking it
# there silently skipped this fix whenever the user picks "managed"
# interactively rather than via --ssl-mode, and nginx would then fail to
# bind at step_build_and_start with the fix step already marked done.
ensure_unprivileged_ports() {
    local http_port="$1" https_port="$2"
    local min_port="$http_port"
    [ "$https_port" -lt "$min_port" ] && min_port="$https_port"

    local start_port
    start_port=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
    if [ "$start_port" -gt "$min_port" ]; then
        log "Ports $http_port/$https_port need net.ipv4.ip_unprivileged_port_start=$min_port for rootless Docker to bind them."
        if ! $NONINTERACTIVE; then
            confirm "Apply this via sudo now (writes /etc/sysctl.d/90-eka-rootless-ports.conf)?" || { echo "Aborting: cannot bind privileged ports without this."; exit 1; }
        fi
        if $DRY_RUN; then
            echo "[dry-run] would run: sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=$min_port > /etc/sysctl.d/90-eka-rootless-ports.conf && sysctl --system'"
        else
            sudo sh -c "echo net.ipv4.ip_unprivileged_port_start=$min_port > /etc/sysctl.d/90-eka-rootless-ports.conf && sysctl --system"
        fi
    fi
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
        ensure_unprivileged_ports "$HTTP_PORT" "$HTTPS_PORT"

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

    [ -n "$CLI_IMAGE" ] && APP_IMAGE="$CLI_IMAGE"
    ask "Pre-built image to run, e.g. ekacare/ekapython-webhook-sdk:v1.2.3 (leave blank to build from the local Dockerfile)" APP_IMAGE "" false false
    set_env_var "$CONFIG_FILE" APP_IMAGE "$APP_IMAGE"

    ask "Client integration to use (metropolis/miracles)" CLIENT_NAME "metropolis" false true
    while [[ "$CLIENT_NAME" != "metropolis" && "$CLIENT_NAME" != "miracles" ]]; do
        if $NONINTERACTIVE; then
            echo "Error: CLIENT_NAME must be 'metropolis' or 'miracles' (got '$CLIENT_NAME')." >&2
            exit 1
        fi
        read -r -p "CLIENT_NAME must be 'metropolis' or 'miracles' - try again: " CLIENT_NAME
    done
    set_env_var "$CONFIG_FILE" CLIENT_NAME "$CLIENT_NAME"

    [ "${CLIENT_ID:-}" == "YOUR_CLIENT_ID" ] && CLIENT_ID=""
    ask "Client ID" CLIENT_ID "" false true true
    set_env_var "$CONFIG_FILE" CLIENT_ID "$CLIENT_ID"

    [ "${CLIENT_SECRET:-}" == "YOUR_CLIENT_SECRET" ] && CLIENT_SECRET=""
    ask "Client Secret" CLIENT_SECRET "" true true true
    set_env_var "$CONFIG_FILE" CLIENT_SECRET "$CLIENT_SECRET"

    [ "${API_KEY:-}" == "YOUR_API_KEY" ] && API_KEY=""
    ask "API Key" API_KEY "" true true true
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
    else
        local want_signing_prompt=false
        if [ -n "$FIELDS_TO_CHANGE" ]; then
            field_should_prompt "SIGNING_KEY" && want_signing_prompt=true
        elif ! $NONINTERACTIVE && ! $CONFIG_CONFIRMED; then
            want_signing_prompt=true
        fi
        if $want_signing_prompt; then
            local new_signing_key
            read -r -p "Signing Key [existing: (hidden), Enter to keep]: " new_signing_key
            [ -n "$new_signing_key" ] && SIGNING_KEY="$new_signing_key"
        fi
    fi
    set_env_var "$CONFIG_FILE" SIGNING_KEY "$SIGNING_KEY"

    if [ "$CLIENT_NAME" == "metropolis" ]; then
        [ "${YELLOW_AI_API_KEY:-}" == "YOUR_YELLOW_AI_API_KEY" ] && YELLOW_AI_API_KEY=""
        ask "Yellow.ai API Key (optional, Enter to skip)" YELLOW_AI_API_KEY "" true false true
        set_env_var "$CONFIG_FILE" YELLOW_AI_API_KEY "$YELLOW_AI_API_KEY"

        [ "${JAPI_KEY:-}" == "YOUR_JAPI_KEY" ] && JAPI_KEY=""
        ask "JAPI Key (optional, Enter to skip)" JAPI_KEY "" true false true
        set_env_var "$CONFIG_FILE" JAPI_KEY "$JAPI_KEY"

        [ "${JAPI_AUTHORIZATION:-}" == "YOUR_JAPI_AUTHORIZATION" ] && JAPI_AUTHORIZATION=""
        ask "JAPI Authorization (optional, Enter to skip)" JAPI_AUTHORIZATION "" true false true
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
    compose config -q || { echo "Error: compose config validation failed - fix config.env and retry." >&2; exit 1; }
    state_mark_done "config_validate"
}

step_build_and_start() {
    if step_done "build_and_start" && ! $FRESH; then log "build_and_start: already done, skipping"; return; fi

    if [ -n "${APP_IMAGE:-}" ]; then
        export APP_IMAGE
        log "Using image $APP_IMAGE (skipping local build)"
    else
        compose build app
    fi

    if ! compose up -d; then
        echo "Start failed, reverting (docker compose down)..." >&2
        compose down || true
        exit 1
    fi

    state_mark_done "build_and_start"
}

# Prints what's needed to enable HTTPS once DNS is actually pointed here -
# shared by the failure path below and step_finalize's end-of-run summary.
print_ssl_todo() {
    local domain="$1"
    echo "  To enable HTTPS:"
    echo "    1. Point a DNS A record for $domain at this host's public IP."
    echo "    2. Verify it resolves:  dig +short $domain"
    echo "    3. Re-run:              $0 install"
    echo "       (this only retries the certificate step - nothing else is redone)"
}

# SSL is deliberately NOT mandatory for the app to run - the most common
# failure here is DNS simply not pointing at this host yet (e.g. a client
# hasn't set it up by the time this runs), and the app is already reachable
# over plain HTTP via nginx's phase-1 bootstrap config regardless of whether
# this succeeds. On failure this asks whether to continue running over HTTP
# rather than tearing the whole deployment down, and is only marked done on
# actual success - so a later plain 'install' re-run (once DNS is fixed)
# automatically retries just this step, no --fresh needed.
step_ssl_cert() {
    [ "$SSL_MODE" == "managed" ] || return 0
    if [ -f "$SCRIPT_DIR/nginx/ssl-enabled/nginx-https.conf" ]; then
        return 0
    fi
    if step_done "ssl_cert" && ! $FRESH; then log "ssl_cert: already done, skipping"; return; fi

    local domain
    domain=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
    log "Requesting a Let's Encrypt certificate for $domain..."
    if $DRY_RUN; then
        echo "[dry-run] would run: certbot certonly --webroot -w /var/www/certbot -d $domain"
        echo "[dry-run] would render nginx/ssl-enabled/nginx-https.conf and reload nginx"
        return 0
    fi

    if compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
        -d "$domain" --non-interactive --agree-tos -m "admin@${domain}" --no-eff-email; then
        EXTERNAL_DOMAIN="$domain" PORT="$PORT" HTTPS_PORT="${HTTPS_PORT:-443}" \
            envsubst '${EXTERNAL_DOMAIN} ${PORT} ${HTTPS_PORT}' \
            < "$SCRIPT_DIR/nginx/nginx-https.conf.example" > "$SCRIPT_DIR/nginx/ssl-enabled/nginx-https.conf"
        compose exec nginx nginx -s reload
        state_mark_done "ssl_cert"
        log "Certificate issued - $EXTERNAL_URL is now served over HTTPS."
        return 0
    fi

    echo "Warning: certificate issuance failed for $domain (see certbot output above - usually DNS not pointing here yet)." >&2
    if $NONINTERACTIVE; then
        log "Continuing over plain HTTP (--non-interactive: not prompting). Re-run 'install' once DNS is fixed to retry."
    elif ! confirm "Continue running the app over plain HTTP for now (fix DNS and retry SSL later)?"; then
        echo "Aborting: fix DNS for $domain, then re-run 'install' to retry." >&2
        compose down || true
        exit 1
    fi
    echo
    print_ssl_todo "$domain"
    echo
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
    if [ "$SSL_MODE" == "managed" ]; then
        if [ -f "$SCRIPT_DIR/nginx/ssl-enabled/nginx-https.conf" ]; then
            if [ "${HTTPS_PORT:-443}" != "443" ]; then
                echo "                (nginx is listening on non-standard HTTPS_PORT=$HTTPS_PORT - include it in the URL: ${EXTERNAL_URL}:${HTTPS_PORT})"
            fi
        else
            local ssl_domain
            ssl_domain=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##')
            echo "  SSL:          not yet enabled - serving plain HTTP only on port ${HTTP_PORT:-80} for now."
            print_ssl_todo "$ssl_domain"
        fi
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
    # shellcheck source=config.env
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

# Some users hand-craft config.env before running install instead of
# answering prompts. If it already existed before this run, show what's in
# it (secrets masked) and ask once whether to use it as-is - if so, ask()
# and the SIGNING_KEY prompt stop re-confirming already-set values
# field-by-field for the rest of this run (CONFIG_CONFIRMED). Sudo
# confirmations for system changes (Docker/iptables/kernel modules/etc.)
# are untouched and still asked normally - this only affects config VALUES.
# Any field still blank in the file is unaffected either way - it's
# prompted for (or errors, under --non-interactive) as usual.
confirm_existing_config() {
    $NONINTERACTIVE && return 0

    echo
    log "Found an existing $(basename "$CONFIG_FILE") - here's what's configured:"
    echo "  PORT=${PORT:-}"
    echo "  EXTERNAL_URL=${EXTERNAL_URL:-}"
    echo "  APP_IMAGE=${APP_IMAGE:-(build locally from Dockerfile)}"
    echo "  SSL_MODE=${SSL_MODE:-}"
    if [ "${SSL_MODE:-}" == "managed" ]; then
        echo "  HTTP_PORT=${HTTP_PORT:-80}"
        echo "  HTTPS_PORT=${HTTPS_PORT:-443}"
    fi
    echo "  CLIENT_NAME=${CLIENT_NAME:-}"
    echo "  CLIENT_ID=${CLIENT_ID:-}"
    echo "  CLIENT_SECRET=$([ -n "${CLIENT_SECRET:-}" ] && echo '(set)' || echo '(blank)')"
    echo "  API_KEY=$([ -n "${API_KEY:-}" ] && echo '(set)' || echo '(blank)')"
    echo "  SIGNING_KEY=$([ -n "${SIGNING_KEY:-}" ] && echo '(set)' || echo '(blank, will be generated)')"
    if [ "${CLIENT_NAME:-}" == "metropolis" ]; then
        echo "  YELLOW_AI_API_KEY=$([ -n "${YELLOW_AI_API_KEY:-}" ] && echo '(set)' || echo '(blank, optional)')"
        echo "  JAPI_KEY=$([ -n "${JAPI_KEY:-}" ] && echo '(set)' || echo '(blank, optional)')"
        echo "  JAPI_AUTHORIZATION=$([ -n "${JAPI_AUTHORIZATION:-}" ] && echo '(set)' || echo '(blank, optional)')"
    fi
    echo

    local confirm
    read -r -p "Use this configuration as-is (skip per-field prompts, keep every value exactly as in the file)? [Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        log "Using $(basename "$CONFIG_FILE") as-is for this run."
        CONFIG_CONFIRMED=true
        return
    fi

    local fields
    read -r -p "Which field(s) do you want to change? (space/comma-separated names, e.g. CLIENT_SECRET API_KEY - leave blank to review every field one by one): " fields
    if [ -n "$fields" ]; then
        FIELDS_TO_CHANGE=$(echo "$fields" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')
        log "Only re-prompting for: $FIELDS_TO_CHANGE - everything else keeps its value from $(basename "$CONFIG_FILE")."
    fi
}

cmd_install() {
    local config_pre_existed=false
    [ -f "$CONFIG_FILE" ] && config_pre_existed=true

    verify_setup
    $config_pre_existed && confirm_existing_config
    state_init
    step_preflight
    step_docker_install
    step_network_create
    step_ssl_setup
    step_generate_env
    step_config_validate
    step_build_and_start
    step_ssl_cert
    step_health_check
    step_webhook_register
    step_finalize
}

cmd_upgrade() {
    verify_setup
    state_init
    [ -n "$CLI_IMAGE" ] && APP_IMAGE="$CLI_IMAGE"
    if [ -n "${APP_IMAGE:-}" ]; then
        export APP_IMAGE
        set_env_var "$CONFIG_FILE" APP_IMAGE "$APP_IMAGE"
        log "Using image $APP_IMAGE"
    else
        compose build app
    fi
    compose up -d
    step_health_check
    log "Upgrade complete."
}

# Stops and removes containers only - volumes (certbot_certs/certbot_webroot)
# and the eka-net network are left untouched, unlike 'uninstall' below.
cmd_stop() {
    load_config_file
    if ! $NONINTERACTIVE; then
        confirm "This stops and removes eka-webhook containers (volumes/certs/network are kept). Continue?" || { echo "Aborted."; exit 0; }
    fi
    compose down
    echo "Containers stopped and removed. Config, volumes, certs, and the eka-net network were left in place."
    echo "Bring it back up with: $0 install   (or) $0 upgrade"
}

cmd_uninstall() {
    load_config_file
    if ! $NONINTERACTIVE; then
        confirm "This stops and removes eka-webhook containers and named volumes. Continue?" || { echo "Aborted."; exit 0; }
    fi
    compose down -v
    if ! $NONINTERACTIVE; then
        if confirm "Also remove the docker network 'eka-net'?"; then
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
    stop) cmd_stop ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    register-webhook) cmd_register_webhook ;;
    *) usage; exit 1 ;;
esac
