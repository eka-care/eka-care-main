#!/usr/bin/env python3
"""Interactive installer for the eka-webhook service on bare metal / VM / local
Linux hosts (no AWS dependency).

Stdlib-only (no pip install needed) - see docs/bare-metal.md for full
documentation. This is the real installer; deploy-local.sh is a thin wrapper
kept so existing docs / muscle memory still work.

Usage: ./deploy-local.sh [install|upgrade|stop|uninstall|status|register-webhook|help] [options]
"""
import getpass
import json
import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

if sys.version_info < (3, 8):
    print("Error: deploy.py needs Python 3.8+.", file=sys.stderr)
    sys.exit(1)

# stdout is fully block-buffered (not line-buffered) whenever it's not a
# terminal (piped to a file/tee/less, or captured by another process) -
# without this, log()/print() output can appear wildly out of order relative
# to stderr (unbuffered) and subprocess output (inherits our fds directly).
try:
    sys.stdout.reconfigure(line_buffering=True)
except (AttributeError, ValueError):
    pass

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG_FILE = SCRIPT_DIR / "config.env"
DEFAULT_COMPOSE_FILE = SCRIPT_DIR / "docker-compose.yml"
STATE_DIR = Path.home() / ".eka-deploy"
STATE_FILE = STATE_DIR / "state.json"

# get.docker.com/rootless always installs to ~/bin and sets it as the default
# CLI context - but this process is a non-interactive Python run, so it never
# sources ~/.bashrc the way an interactive login shell would. A previously
# installed rootless Docker would otherwise look "not found" (PATH inherited
# from the invoking shell doesn't include ~/bin) even though it's fine, so
# check/point at the well-known install location directly.
_home_bin = Path.home() / "bin"
if _home_bin.is_dir():
    os.environ["PATH"] = f"{_home_bin}{os.pathsep}{os.environ.get('PATH', '')}"
if not os.environ.get("DOCKER_HOST"):
    _runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    _sock = Path(_runtime) / "docker.sock"
    try:
        if _sock.is_socket():
            os.environ["DOCKER_HOST"] = f"unix://{_sock}"
    except OSError:
        pass

ACTIONS = ("install", "upgrade", "stop", "uninstall", "status", "register-webhook", "help")
PROG = "./deploy-local.sh"

NGINX_BLOCK_SKIP_MARKER = "#EKA-SKIP-NGINX# "

USAGE = f"""Usage: {PROG} [install|upgrade|stop|uninstall|status|register-webhook|help] [options]

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
  --debug                   Verbose output (trace subprocess commands)
  --non-interactive         Never prompt; fail if a required value is missing
  --skip-docker-install     Assume Docker/compose are already installed
  --skip-nginx              Comment out nginx/certbot in docker-compose.yml
                              entirely and force --ssl-mode external (no
                              managed SSL, no DNS/cert requirement at all).
                              Reversible: omit the flag on a later run and
                              the block is automatically uncommented again.
  --skip-webhook-register   Don't register the webhook with Eka Care during
                              install (deploy the container only). Register
                              later with: {PROG} register-webhook
  --env-file PATH            Path to the env file (default: config.env,
                              materialized from config.env.example if missing)
  --docker-compose-file PATH Path to the compose file (default: docker-compose.yml
                              in the script directory)
  --port PORT
  --external-url URL
  --ssl-mode managed|external
  --image REF                Use a pre-built image instead of building locally
  -h, --help                 Show this help
"""


# ---- global state -----------------------------------------------------------

class State:
    def __init__(self):
        self.action = "install"
        self.dry_run = False
        self.fresh = False
        self.debug = False
        self.non_interactive = False
        self.skip_docker_install = False
        self.skip_nginx = False
        self.skip_webhook_register = False
        # Set true once the user confirms an existing config.env is fine as-is
        # (see confirm_existing_config) - suppresses ask()'s per-field
        # "existing: ..., Enter to keep" walkthrough for already-set values,
        # WITHOUT touching non_interactive (which also gates sudo confirmations
        # for system changes - those must still be asked regardless).
        self.config_confirmed = False
        # Uppercase field names the user explicitly asked to change, or []
        # meaning "no specific list" (normal per-field behavior applies).
        self.fields_to_change = []
        # Set true when the user declines "use as-is" in confirm_existing_config
        # (whether or not they then named specific fields). Value-collecting
        # steps bypass their normal step_done() skip when this is set, so ask()
        # gets a chance to re-prompt and new values reach the container.
        # Deliberately does NOT bypass preflight/docker_install/network_create.
        self.reconfigure = False
        # Every field name ask() actually evaluated this run - see
        # warn_unmatched_fields_to_change().
        self.known_ask_fields = set()
        self.confirm_all = False

        self.cli_port = None
        self.cli_external_url = None
        self.cli_ssl_mode = None
        self.cli_image = None
        self.cli_env_file = None
        self.cli_compose_file = None

        self.config_file = DEFAULT_CONFIG_FILE
        self.compose_file = DEFAULT_COMPOSE_FILE
        self.ssl_mode = ""
        self.external_url = ""
        self.values = {}  # current contents of config_file


def log(msg):
    print(f"[eka-deploy] {msg}")


def debug(state, msg):
    if state.debug:
        print(f"[debug] {msg}", file=sys.stderr)


def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


# Set true once the user answers "a"/"A" ("yes to all") at any confirm()
# prompt - every confirm() call for the rest of this run is then answered yes
# automatically. Callers are still responsible for checking non_interactive
# themselves before calling this (matches every call site's structure).
def confirm(state, prompt):
    if state.confirm_all:
        return True
    answer = input(f"{prompt} [y/N/a]: ").strip()
    if answer.lower() == "a":
        state.confirm_all = True
        return True
    return answer.lower() == "y"


def random_hex(nbytes):
    return secrets.token_hex(nbytes)


# ---- CLI parsing --------------------------------------------------------------

def parse_args(argv):
    state = State()
    args = list(argv)

    if args and args[0] in ACTIONS:
        state.action = args.pop(0)
    elif args and args[0] in ("-h", "--help"):
        print(USAGE)
        sys.exit(0)

    if state.action == "help":
        print(USAGE)
        sys.exit(0)

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--dry-run":
            state.dry_run = True; i += 1
        elif a == "--fresh":
            state.fresh = True; i += 1
        elif a == "--debug":
            state.debug = True; i += 1
        elif a == "--non-interactive":
            state.non_interactive = True; i += 1
        elif a == "--skip-docker-install":
            state.skip_docker_install = True; i += 1
        elif a == "--skip-nginx":
            state.skip_nginx = True; i += 1
        elif a == "--skip-webhook-register":
            state.skip_webhook_register = True; i += 1
        elif a == "--env-file":
            state.cli_env_file = args[i + 1]; i += 2
        elif a == "--docker-compose-file":
            state.cli_compose_file = args[i + 1]; i += 2
        elif a == "--port":
            state.cli_port = args[i + 1]; i += 2
        elif a == "--external-url":
            state.cli_external_url = args[i + 1]; i += 2
        elif a == "--ssl-mode":
            state.cli_ssl_mode = args[i + 1]; i += 2
        elif a == "--image":
            state.cli_image = args[i + 1]; i += 2
        elif a in ("-h", "--help"):
            print(USAGE)
            sys.exit(0)
        else:
            print(f"Error: unknown option '{a}'", file=sys.stderr)
            print(USAGE)
            sys.exit(1)

    if state.cli_env_file:
        state.config_file = Path(state.cli_env_file)
    if state.cli_compose_file:
        state.compose_file = Path(state.cli_compose_file)

    if state.skip_nginx:
        if state.cli_ssl_mode == "managed":
            die("--skip-nginx and --ssl-mode managed conflict - managed SSL needs nginx/certbot.")
        state.cli_ssl_mode = "external"

    return state


# ---- env file helpers ---------------------------------------------------------

_QUOTE_RE = re.compile(r'^(["\'])(.*)\1$')


def _unquote(value):
    m = _QUOTE_RE.match(value)
    return m.group(2) if m else value


def load_env_file(path: Path) -> dict:
    values = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, val = stripped.partition("=")
        values[key.strip()] = _unquote(val.strip())
    return values


def set_env_var(state, key, value):
    if state.dry_run:
        print(f"[dry-run] would set {key} in {state.config_file.name}")
        state.values[key] = value
        return
    lines = state.config_file.read_text().splitlines(keepends=True) if state.config_file.exists() else []
    prefix = f"{key}="
    for idx, line in enumerate(lines):
        if line.startswith(prefix):
            lines[idx] = f"{key}={value}\n"
            break
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key}={value}\n")
    state.config_file.write_text("".join(lines))
    state.values[key] = value


def field_should_prompt(state, varname):
    return varname in state.fields_to_change


# Warns (doesn't fail - the run already completed) about any named field that
# no ask() call actually looked at, so a typo or a conditionally-irrelevant
# field (e.g. HTTP_PORT while SSL_MODE=external) is surfaced instead of
# silently doing nothing.
def warn_unmatched_fields_to_change(state):
    if not state.fields_to_change:
        return
    unmatched = [f for f in state.fields_to_change if f not in state.known_ask_fields]
    if not unmatched:
        return
    log(f"Warning: requested field(s) were never prompted this run: {' '.join(unmatched)}")
    log("  Either the name doesn't match a real config.env field, or it only applies under different settings")
    log("  (e.g. HTTP_PORT/HTTPS_PORT only prompt when SSL_MODE=managed). Edit config.env directly if needed,")
    log("  then re-run install to validate.")


# ask() drives every config-value prompt. When the field already has a value:
# re-prompt only if the user named it in fields_to_change, or - when they
# declined "use as-is" (reconfigure) or the caller marks the field worth
# surfacing (confirm_existing) - offer an "Enter to keep" walkthrough. The
# `reconfigure` clause is what makes "review every field" review EVERY field,
# not just the credential ones (which is exactly what the bash version was
# missing). A blank/unset field falls through to a normal prompt (fresh
# install, blanked placeholder, etc.).
def ask(state, prompt, varname, default="", secret=False, required=False, confirm_existing=False):
    state.known_ask_fields.add(varname)
    current = state.values.get(varname, "")

    if current:
        want_prompt = False
        if state.fields_to_change:
            want_prompt = field_should_prompt(state, varname)
        elif (confirm_existing or state.reconfigure) and not state.non_interactive and not state.config_confirmed:
            want_prompt = True
        if not want_prompt:
            return current
        if secret:
            answer = getpass.getpass(f"{prompt} [existing: (hidden), Enter to keep]: ")
        else:
            answer = input(f"{prompt} [existing: {current}, Enter to keep]: ")
        return answer if answer else current

    if state.non_interactive:
        if default:
            return default
        if required:
            die(f"{varname} is required but not set. Pre-fill it in {state.config_file} or pass it as a flag.")
        return ""

    while True:
        if secret:
            answer = getpass.getpass(f"{prompt}: ")
        elif default:
            answer = input(f"{prompt} [{default}]: ").strip()
            answer = answer if answer else default
        else:
            answer = input(f"{prompt}: ")
        if answer or not required:
            return answer
        print("This value is required.")


# Like ask(), but auto-generates a random secret when left blank instead of
# erroring. Callers must clear known placeholders to "" first, or this
# mistakes the placeholder for a real saved value.
def ask_or_generate(state, prompt, varname, nbytes):
    state.known_ask_fields.add(varname)
    current = state.values.get(varname, "")

    if current:
        want_prompt = False
        if state.fields_to_change:
            want_prompt = field_should_prompt(state, varname)
        elif state.reconfigure and not state.non_interactive and not state.config_confirmed:
            want_prompt = True
        if want_prompt:
            answer = getpass.getpass(f"{prompt} [existing: (hidden), Enter to keep]: ")
            if answer:
                current = answer
        return current

    if state.non_interactive:
        value = random_hex(nbytes)
        log(f"Generated {varname}")
        return value

    answer = getpass.getpass(f"{prompt} (leave blank to auto-generate): ")
    if answer:
        return answer
    log(f"Generated {varname}")
    return random_hex(nbytes)


# ---- connectivity / networking helpers -----------------------------------------

def parse_registry_host(ref):
    first_segment = ref.split("/", 1)[0]
    if "." in first_segment or ":" in first_segment or first_segment == "localhost":
        return first_segment
    return "registry-1.docker.io"


def check_tcp(host, port, timeout=5):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, ""
    except OSError as e:
        return False, str(e)


# Retries a single endpoint with backoff before giving up - client firewalls
# often block outbound traffic, and a single flaky attempt shouldn't fail the
# whole run. Does not exit: returns False so the caller can check every
# endpoint and report all blocked ones together.
def check_connectivity(host, port, label):
    attempt, max_attempts, delay = 1, 3, 3
    while True:
        ok, err = check_tcp(host, port)
        if ok:
            print(f"[eka-deploy]   OK    {label} ({host}:{port})")
            return True
        if attempt >= max_attempts:
            suffix = f": {err}" if err else ""
            print(f"[eka-deploy]   FAIL  {label} ({host}:{port}) - unreachable after {max_attempts} attempts{suffix}")
            return False
        suffix = f" ({err})" if err else ""
        print(f"[eka-deploy]   ...   {label} ({host}:{port}) unreachable{suffix}, retrying in {delay}s "
              f"(attempt {attempt + 1}/{max_attempts})")
        time.sleep(delay)
        attempt += 1
        delay *= 2


def dns_sanity_check(domain):
    if not which("dig"):
        log(f"dig not installed, skipping DNS sanity check for {domain}")
        return
    try:
        resolved = subprocess.run(["dig", "+short", domain], capture_output=True, text=True).stdout.strip().splitlines()
        resolved = resolved[-1] if resolved else ""
    except OSError:
        resolved = ""
    public_ip = ""
    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=5) as r:
            public_ip = r.read().decode().strip()
    except Exception:
        public_ip = ""
    if resolved and public_ip and resolved != public_ip:
        log(f"Warning: {domain} resolves to '{resolved}' but this machine's public IP looks like '{public_ip}'.")
        log(f"Certbot's HTTP-01 challenge will fail until DNS points {domain} here.")


def port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", int(port)))
            return False
        except OSError:
            return True


# ---- shell-out helpers ---------------------------------------------------------

def run(cmd, check=True, capture=False, input_text=None, env=None):
    kwargs = {}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
        kwargs["text"] = True
    if input_text is not None:
        kwargs["input"] = input_text
        kwargs["text"] = True
    result = subprocess.run(cmd, env=env, **kwargs)
    if check and result.returncode != 0:
        die(f"command failed: {' '.join(str(c) for c in cmd)}")
    return result


def run_dry(state, cmd, dry_msg=None, check=True, env=None):
    if state.dry_run:
        print(f"[dry-run] would run: {' '.join(str(c) for c in cmd)}" if dry_msg is None else f"[dry-run] {dry_msg}")
        return True
    result = subprocess.run(cmd, env=env)
    if check and result.returncode != 0:
        return False
    return result.returncode == 0


def which(name):
    return shutil.which(name) is not None


def docker_present():
    return which("docker")


def compose_plugin_ok():
    return subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0


def require_cmd(name):
    if not which(name):
        die(f"'{name}' is required but not installed.")


# ---- rootless docker / prerequisites -------------------------------------------

def detect_pkg_manager():
    for mgr in ("apt-get", "dnf", "yum", "zypper"):
        if which(mgr):
            return mgr
    return None


def pkg_name_for(binary, mgr):
    if binary in ("curl", "jq", "iptables"):
        return binary
    if binary == "newuidmap":
        if mgr == "apt-get":
            return "uidmap"
        if mgr in ("dnf", "yum"):
            return "shadow-utils"
        if mgr == "zypper":
            return "shadow"
    return binary


def ensure_installed(state, purpose, *binaries):
    missing = [b for b in binaries if not which(b)]
    if not missing:
        return

    mgr = detect_pkg_manager()
    if not mgr:
        log(f"Warning: missing {' '.join(missing)} for {purpose}, and no known package manager "
            "(apt-get/dnf/yum/zypper) detected.")
        log("Install these manually before continuing.")
        return

    pkgs = [pkg_name_for(b, mgr) for b in missing]
    log(f"{purpose} needs: {' '.join(missing)} (missing). Package(s) to install via {mgr}: {' '.join(pkgs)}")
    if not state.non_interactive:
        if not confirm(state, f"Install missing prerequisites ({' '.join(pkgs)}) via sudo {mgr} now?"):
            die(f"{purpose} requires {' '.join(missing)}.")
    if mgr == "apt-get":
        run_dry(state, ["sudo", "apt-get", "update"])
        run_dry(state, ["sudo", "apt-get", "install", "-y", *pkgs])
    else:
        run_dry(state, ["sudo", mgr, "install", "-y", *pkgs])


def ensure_kernel_modules(state, *modules):
    missing = []
    for mod in modules:
        loaded = subprocess.run(["lsmod"], capture_output=True, text=True)
        if not any(line.split()[:1] == [mod] for line in loaded.stdout.splitlines()):
            missing.append(mod)
    if not missing:
        return

    log(f"Kernel module(s) not loaded (required for rootless Docker's iptables/nftables setup): {' '.join(missing)}")
    if not state.non_interactive:
        if not confirm(state, f"Load {' '.join(missing)} now via sudo modprobe?"):
            die(f"rootless Docker requires: {' '.join(missing)}.")
    if state.dry_run:
        print(f"[dry-run] would run: sudo modprobe {' '.join(missing)}")
        print(f"[dry-run] would persist {' '.join(missing)} to /etc/modules-load.d/eka-docker.conf")
        return
    run(["sudo", "modprobe", *missing])
    run(["sudo", "tee", "/etc/modules-load.d/eka-docker.conf"],
        input_text="\n".join(missing) + "\n", capture=True)


def ensure_clean_rootless_install(state):
    dockerd_bin = Path.home() / "bin" / "dockerd"
    if not dockerd_bin.exists():
        return
    log(f"Found a leftover rootless Docker binary at {dockerd_bin} from a previous incomplete install.")
    if not state.non_interactive:
        if not confirm(state, "Remove it and retry installation?"):
            die(f"remove {dockerd_bin} manually (after 'systemctl --user stop docker') and re-run, "
                "or pass --skip-docker-install if Docker is already usable.")
    if state.dry_run:
        print("[dry-run] would run: systemctl --user stop docker (best-effort)")
        print(f"[dry-run] would run: rm -f {dockerd_bin}")
        return
    subprocess.run(["systemctl", "--user", "stop", "docker"], capture_output=True)
    dockerd_bin.unlink(missing_ok=True)


def ensure_apparmor_userns_allowed(state):
    restrict_file = Path("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
    if not restrict_file.is_file():
        return
    try:
        if restrict_file.read_text().strip() != "1":
            return
    except OSError:
        return
    if not which("apparmor_parser"):
        return

    rootlesskit_bin = Path.home() / "bin" / "rootlesskit"
    profile_name = str(rootlesskit_bin).lstrip("/").replace("/", ".")
    profile_path = Path("/etc/apparmor.d") / profile_name
    if profile_path.is_file():
        return

    log("AppArmor is restricting unprivileged user namespaces "
        "(kernel.apparmor_restrict_unprivileged_userns=1) - rootless Docker's rootlesskit needs an "
        "exemption, or it fails with 'permission denied'.")
    if not state.non_interactive:
        if not confirm(state, f"Install an AppArmor profile allowing rootlesskit ({rootlesskit_bin}) "
                              "unconfined userns access, via sudo?"):
            die("rootless Docker cannot start without this. See https://rootlesscontaine.rs/getting-started/common/")

    profile = (
        "abi <abi/4.0>,\n"
        "include <tunables/global>\n\n"
        f"{rootlesskit_bin} flags=(unconfined) {{\n"
        "  userns,\n\n"
        f"  include if exists <local/{profile_name}>\n"
        "}\n"
    )
    if state.dry_run:
        print(f"[dry-run] would write {profile_path} and run: sudo systemctl restart apparmor.service")
        return
    run(["sudo", "tee", str(profile_path)], input_text=profile, capture=True)
    run(["sudo", "systemctl", "restart", "apparmor.service"])


def ensure_compose_plugin(state):
    if not compose_plugin_ok():
        log("Docker Compose CLI plugin not found ('docker compose' is unrecognized).")
        if not state.non_interactive:
            if not confirm(state, "Download and install it now (to ~/.docker/cli-plugins/docker-compose)?"):
                die("the Docker Compose plugin is required.")

        arch = platform.machine()
        urls = {
            "x86_64": "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64",
            "aarch64": "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64",
        }
        if arch not in urls:
            die(f"no known Docker Compose plugin build for architecture '{arch}'. Install it manually: "
                "https://docs.docker.com/compose/install/linux/#install-the-plugin-manually")
        dest = Path.home() / ".docker" / "cli-plugins" / "docker-compose"
        if state.dry_run:
            print(f"[dry-run] would download {urls[arch]} -> {dest} (chmod +x)")
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                with urllib.request.urlopen(urls[arch], timeout=60) as r:
                    dest.write_bytes(r.read())
            except Exception as e:
                die(f"failed to download the Docker Compose plugin from {urls[arch]}: {e}")
            dest.chmod(0o755)
            if not compose_plugin_ok():
                die("Docker Compose plugin installed but 'docker compose version' still fails.")

    # Provide a thin docker-compose -> 'docker compose' shim for tooling/muscle
    # memory expecting the old hyphenated binary. No-op if something already
    # provides docker-compose.
    if not which("docker-compose"):
        shim = Path.home() / "bin" / "docker-compose"
        if state.dry_run:
            print(f"[dry-run] would write a docker-compose -> 'docker compose' shim to {shim}")
        else:
            shim.parent.mkdir(parents=True, exist_ok=True)
            shim.write_text('#!/bin/sh\nexec docker compose "$@"\n')
            shim.chmod(0o755)
            log(f"Added a docker-compose -> 'docker compose' shim at {shim} "
                "(for tooling/scripts expecting the old binary name).")


def persist_rootless_docker_env(state):
    rc_file = Path.home() / ".bashrc"
    marker = "# Added by eka-webhook deploy-local.sh (rootless Docker)"
    if rc_file.exists() and marker in rc_file.read_text():
        return
    if state.dry_run:
        print(f"[dry-run] would append PATH/DOCKER_HOST exports for rootless Docker to {rc_file}")
        return
    with rc_file.open("a") as f:
        f.write("\n" + marker + "\n")
        f.write('export PATH="$HOME/bin:$PATH"\n')
        f.write('export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"\n')
    log(f"Added rootless Docker's PATH/DOCKER_HOST to {rc_file} - open a new shell (or 'source {rc_file}') "
        "to use 'docker'/'docker compose' directly, without the ~/bin/ prefix.")


# Rootless Docker can't bind ports <1024 unless the kernel allows it (via
# net.ipv4.ip_unprivileged_port_start). Only relevant for managed SSL (nginx
# binds 80/443).
def ensure_unprivileged_ports(state, http_port, https_port):
    min_port = min(int(http_port), int(https_port))
    try:
        start_port = int(subprocess.run(["sysctl", "-n", "net.ipv4.ip_unprivileged_port_start"],
                                        capture_output=True, text=True).stdout.strip() or 1024)
    except (OSError, ValueError):
        start_port = 1024
    if start_port > min_port:
        log(f"Ports {http_port}/{https_port} need net.ipv4.ip_unprivileged_port_start={min_port} "
            "for rootless Docker to bind them.")
        if not state.non_interactive:
            if not confirm(state, "Apply this via sudo now (writes /etc/sysctl.d/90-eka-rootless-ports.conf)?"):
                die("cannot bind privileged ports without this.")
        content = f"net.ipv4.ip_unprivileged_port_start={min_port}\n"
        if state.dry_run:
            print(f"[dry-run] would write {content.strip()} to /etc/sysctl.d/90-eka-rootless-ports.conf "
                  "and run: sudo sysctl --system")
            return
        run(["sudo", "tee", "/etc/sysctl.d/90-eka-rootless-ports.conf"], input_text=content, capture=True)
        run(["sudo", "sysctl", "--system"], capture=True)


# ---- state file (~/.eka-deploy/state.json) --------------------------------------
# Tracks step completion only. Actual answers/secrets live in config.env (the
# single source of truth), never duplicated here.

def state_init(state):
    if state.dry_run:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if state.fresh or not STATE_FILE.exists():
        STATE_FILE.write_text(json.dumps(
            {"version": 1, "updated_at": "", "config_file": str(state.config_file), "steps": {}}))
        STATE_FILE.chmod(0o600)


def _load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {"version": 1, "updated_at": "", "steps": {}}


def state_step_status(name):
    return _load_state().get("steps", {}).get(name, "pending")


def state_mark_done(state, name):
    if state.dry_run:
        return
    data = _load_state()
    data.setdefault("steps", {})[name] = "done"
    data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    STATE_FILE.write_text(json.dumps(data))
    STATE_FILE.chmod(0o600)


def step_done(name):
    return state_step_status(name) == "done"


# ---- docker-compose.yml nginx toggle -------------------------------------------
# Idempotently comments out (--skip-nginx) or restores (no --skip-nginx) the
# nginx/certbot block between the eka-nginx-block sentinel comments. Marks
# lines it comments with a unique prefix so uncommenting is exact and
# reversible - lines that were already plain comments inside the block are
# untouched either way.
def apply_skip_nginx(state):
    path = state.compose_file
    lines = path.read_text().splitlines()
    start = end = None
    for idx, line in enumerate(lines):
        stripped = line.lstrip()
        if start is None and stripped.startswith("# eka-nginx-block:start"):
            start = idx
        elif start is not None and stripped.startswith("# eka-nginx-block:end"):
            end = idx
            break
    if start is None or end is None or start >= end:
        log(f"Warning: couldn't find the eka-nginx-block markers in {path.name} (has it been edited "
            "manually?) - skipping the --skip-nginx toggle and using the file as-is.")
        if state.skip_nginx:
            log(f"Note: --skip-nginx was requested but not applied to {path.name} itself. SSL_MODE is still "
                "forced to 'external', so nginx/certbot won't be started regardless - but the compose file's "
                "own nginx/certbot definitions are untouched.")
        return

    if state.dry_run:
        if state.skip_nginx:
            print(f"[dry-run] would comment out the nginx/certbot block in {path.name}")
        else:
            print(f"[dry-run] would ensure the nginx/certbot block in {path.name} is uncommented")
        return

    out = []
    for idx, line in enumerate(lines):
        if start < idx < end:
            if state.skip_nginx:
                if not line.startswith(NGINX_BLOCK_SKIP_MARKER):
                    out.append(NGINX_BLOCK_SKIP_MARKER + line)
                    continue
            else:
                if line.startswith(NGINX_BLOCK_SKIP_MARKER):
                    out.append(line[len(NGINX_BLOCK_SKIP_MARKER):])
                    continue
        out.append(line)
    path.write_text("\n".join(out) + "\n")


# ---- docker compose wrapper -----------------------------------------------------
# Single compose file - this wrapper decides what runs: activates the "ssl"
# profile (nginx + certbot) only when SSL_MODE=managed, and pins the app's
# published bind address to 127.0.0.1 in that case (only nginx should be
# publicly reachable). `config` always runs for real (read-only).
def compose(state, args, check=True, capture=False):
    cmd = ["docker", "compose", "-f", str(state.compose_file)]
    env = os.environ.copy()
    if state.ssl_mode == "managed":
        cmd += ["--profile", "ssl"]
        env["APP_BIND_ADDR"] = "127.0.0.1"
    else:
        env["APP_BIND_ADDR"] = "0.0.0.0"
    cmd += ["--env-file", str(state.config_file)] + [str(a) for a in args]
    if state.dry_run and (not args or args[0] != "config"):
        print(f"[dry-run] would run: {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    result = subprocess.run(cmd, env=env, capture_output=capture, text=True if capture else None)
    if check and result.returncode != 0:
        die(f"command failed: {' '.join(cmd)}")
    return result


def render_template(template_path: Path, output_path: Path, mapping: dict):
    text = template_path.read_text()
    text = re.sub(r"\$\{(\w+)\}", lambda m: str(mapping.get(m.group(1), m.group(0))), text)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text)


# ---- steps ----------------------------------------------------------------------

def step_preflight(state):
    if step_done("preflight") and not state.fresh:
        log("preflight: already done, skipping")
        return
    log("Checking system requirements...")

    if platform.system() != "Linux":
        die("deploy-local.sh only supports Linux (bare metal or VM).")

    try:
        mem_kb = 0
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal"):
                mem_kb = int(line.split()[1])
                break
        mem_gb = mem_kb // 1024 // 1024
    except (OSError, ValueError, IndexError):
        mem_gb = 0
    cpu_count = os.cpu_count() or 1
    disk_avail_gb = shutil.disk_usage(SCRIPT_DIR).free // (1024 ** 3)
    log(f"Machine: {cpu_count} vCPU, {mem_gb}GB RAM, {disk_avail_gb}GB free disk")
    if mem_gb < 1:
        log("Warning: less than 1GB RAM detected.")
    if disk_avail_gb < 2:
        log("Warning: less than 2GB free disk detected.")

    if state.cli_port:
        state.values["PORT"] = state.cli_port
    port = ask(state, "Port to expose the webhook service on", "PORT", state.values.get("PORT", "8080"),
               False, True)
    set_env_var(state, "PORT", port)
    if not state.dry_run and port_in_use(port):
        die(f"port {port} is already in use on this host.")

    log("Checking outbound connectivity (client firewalls commonly block some of these)...")
    conn_failed = False
    if not check_connectivity("www.eka.care", 443, "Eka Care"):
        conn_failed = True
    if not state.skip_webhook_register:
        if not check_connectivity("api.eka.care", 443, "Eka Care API (webhook registration)"):
            conn_failed = True

    registry_host = parse_registry_host(state.cli_image or "registry-1.docker.io/library/python")
    if not check_connectivity(registry_host, 443, "Docker registry (app image)"):
        conn_failed = True

    if not state.skip_docker_install:
        if not docker_present():
            if not check_connectivity("get.docker.com", 443, "Docker install script"):
                conn_failed = True
        if not (docker_present() and compose_plugin_ok()):
            if not check_connectivity("github.com", 443, "Docker Compose plugin download"):
                conn_failed = True
            if not check_connectivity("objects.githubusercontent.com", 443,
                                      "Docker Compose plugin download (redirect target)"):
                conn_failed = True

    known_ssl_mode = state.cli_ssl_mode or state.ssl_mode
    if known_ssl_mode == "managed":
        if registry_host != "registry-1.docker.io":
            if not check_connectivity("registry-1.docker.io", 443, "Docker Hub (nginx/certbot images)"):
                conn_failed = True
        if not check_connectivity("acme-v02.api.letsencrypt.org", 443, "Let's Encrypt"):
            conn_failed = True
        if which("dig"):
            if not check_connectivity("checkip.amazonaws.com", 443, "Public IP lookup (DNS sanity check)"):
                log("  (non-fatal) DNS sanity check will be skipped without this.")

    if conn_failed:
        print("Error: one or more required endpoints are unreachable (see FAIL lines above).", file=sys.stderr)
        print("Ask your network/security team to allow outbound HTTPS to them, then re-run install.",
              file=sys.stderr)
        sys.exit(1)

    state_mark_done(state, "preflight")


def step_docker_install(state):
    if step_done("docker_install") and not state.fresh:
        if docker_present() and compose_plugin_ok():
            log("docker_install: already done, skipping")
            return
        log("docker_install: marked done previously, but Docker/Compose isn't fully working now - rechecking")

    if state.skip_docker_install:
        log("docker_install: --skip-docker-install given, verifying docker is present")
        require_cmd("docker")
        if not compose_plugin_ok():
            die("docker compose plugin not found.")
        state_mark_done(state, "docker_install")
        return

    if docker_present():
        log("Docker already installed")
    else:
        if not state.non_interactive:
            if not confirm(state, "Docker not found. Install rootless Docker now?"):
                die("Docker is required (or re-run with --skip-docker-install once installed).")
        ensure_installed(state, "rootless Docker", "iptables", "newuidmap")
        ensure_kernel_modules(state, "nf_tables", "ip_tables")
        ensure_clean_rootless_install(state)
        ensure_apparmor_userns_allowed(state)

        if state.dry_run:
            print("[dry-run] would run: curl -fsSL https://get.docker.com/rootless | sh")
            print("[dry-run] would run: systemctl --user enable --now docker")
            print("[dry-run] would run: sudo loginctl enable-linger $(whoami)")
        else:
            try:
                with urllib.request.urlopen("https://get.docker.com/rootless", timeout=60) as r:
                    script = r.read()
            except Exception as e:
                die(f"failed to fetch rootless Docker install script: {e}")
            if subprocess.run(["sh"], input=script).returncode != 0:
                die("rootless Docker install script failed (see output above).")
            if subprocess.run(["systemctl", "--user", "list-unit-files", "docker.service"],
                              capture_output=True).returncode != 0:
                print("Error: rootless Docker install script did not finish creating the docker.service "
                      "user unit.", file=sys.stderr)
                print("It may have detected a leftover/partial install and printed manual cleanup steps "
                      "above - follow those and re-run.", file=sys.stderr)
                sys.exit(1)
            run(["systemctl", "--user", "enable", "--now", "docker"])
            whoami = getpass.getuser()
            if subprocess.run(["sudo", "loginctl", "enable-linger", whoami]).returncode != 0:
                log(f"Warning: could not enable linger for {whoami} - docker.service will stop when you log "
                    f"out of this session. Run 'sudo loginctl enable-linger {whoami}' manually to fix.")
            os.environ["PATH"] = f"{Path.home() / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
            runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
            os.environ["DOCKER_HOST"] = f"unix://{Path(runtime) / 'docker.sock'}"
            persist_rootless_docker_env(state)

    ensure_compose_plugin(state)
    state_mark_done(state, "docker_install")


def step_network_create(state):
    if step_done("network_create") and not state.fresh:
        log("network_create: already done, skipping")
        return
    if state.dry_run:
        print("[dry-run] would run: docker network create eka-net (if missing)")
    else:
        if subprocess.run(["docker", "network", "inspect", "eka-net"], capture_output=True).returncode != 0:
            run(["docker", "network", "create", "eka-net"])
    state_mark_done(state, "network_create")


def step_ssl_setup(state):
    if step_done("ssl_setup") and not state.fresh and not state.reconfigure:
        log("ssl_setup: already done, skipping")
        return

    if state.cli_external_url:
        state.values["EXTERNAL_URL"] = state.cli_external_url
    external_url = ask(state, "External URL clients will reach this service on "
                              "(e.g. https://webhook.example.com)", "EXTERNAL_URL", "", False, True, True)
    set_env_var(state, "EXTERNAL_URL", external_url)
    state.external_url = external_url

    if state.cli_ssl_mode:
        state.values["SSL_MODE"] = state.cli_ssl_mode
    ssl_mode = ask(state, "Manage SSL for you via nginx+certbot, or do you already terminate TLS yourself? "
                          "[managed/external]", "SSL_MODE", "external", False, True, True)
    set_env_var(state, "SSL_MODE", ssl_mode)
    state.ssl_mode = ssl_mode

    if ssl_mode == "managed":
        domain = re.sub(r"^https?://", "", external_url).split("/")[0]
        dns_sanity_check(domain)

        http_port = ask(state, "HTTP port nginx publishes (Let's Encrypt's challenge always connects on 80 - "
                               "only change this if something else forwards 80 to it)", "HTTP_PORT",
                        state.values.get("HTTP_PORT", "80"), False, True, True)
        https_port = ask(state, "HTTPS port nginx publishes", "HTTPS_PORT",
                         state.values.get("HTTPS_PORT", "443"), False, True, True)
        set_env_var(state, "HTTP_PORT", http_port)
        set_env_var(state, "HTTPS_PORT", https_port)
        if http_port != "80":
            log(f"Warning: HTTP_PORT={http_port} (not 80). Let's Encrypt's HTTP-01 challenge always")
            log(f"connects on the public port 80, so something else must forward port 80 to {http_port}")
            log("on this host, or certificate issuance will fail.")
        ensure_unprivileged_ports(state, http_port, https_port)

        if state.dry_run:
            print(f"[dry-run] would render nginx/nginx.conf (bootstrap, HTTP-only) for domain {domain}")
        else:
            render_template(
                SCRIPT_DIR / "nginx" / "nginx.conf.example",
                SCRIPT_DIR / "nginx" / "nginx.conf",
                {"EXTERNAL_DOMAIN": domain, "PORT": state.values.get("PORT", "8080"), "HTTP_PORT": http_port},
            )

    state_mark_done(state, "ssl_setup")


def step_generate_env(state):
    if step_done("generate_env") and not state.fresh and not state.reconfigure:
        log("generate_env: already done, skipping")
        return

    if state.cli_image:
        state.values["APP_IMAGE"] = state.cli_image
    app_image = ask(state, "Pre-built image to run, e.g. ekacare/ekapython-webhook-sdk:v1.2.3 "
                           "(leave blank to build from the local Dockerfile)", "APP_IMAGE", "", False, False, True)
    set_env_var(state, "APP_IMAGE", app_image)

    client_name = ask(state, "Client integration to use (metropolis/miracles)", "CLIENT_NAME",
                      "metropolis", False, True, True)
    while client_name not in ("metropolis", "miracles"):
        if state.non_interactive:
            die(f"CLIENT_NAME must be 'metropolis' or 'miracles' (got '{client_name}').")
        client_name = input("CLIENT_NAME must be 'metropolis' or 'miracles' - try again: ").strip()
    set_env_var(state, "CLIENT_NAME", client_name)

    if state.values.get("CLIENT_ID") == "YOUR_CLIENT_ID":
        state.values["CLIENT_ID"] = ""
    client_id = ask(state, "Client ID", "CLIENT_ID", "", False, True, True)
    set_env_var(state, "CLIENT_ID", client_id)

    if state.values.get("CLIENT_SECRET") == "YOUR_CLIENT_SECRET":
        state.values["CLIENT_SECRET"] = ""
    client_secret = ask(state, "Client Secret", "CLIENT_SECRET", "", True, True, True)
    set_env_var(state, "CLIENT_SECRET", client_secret)

    if state.values.get("API_KEY") == "YOUR_API_KEY":
        state.values["API_KEY"] = ""
    api_key = ask(state, "API Key", "API_KEY", "", True, True, True)
    set_env_var(state, "API_KEY", api_key)

    signing_key = ask_or_generate(state, "Signing Key", "SIGNING_KEY", 16)
    set_env_var(state, "SIGNING_KEY", signing_key)

    if client_name == "metropolis":
        if state.values.get("YELLOW_AI_API_KEY") == "YOUR_YELLOW_AI_API_KEY":
            state.values["YELLOW_AI_API_KEY"] = ""
        yellow = ask(state, "Yellow.ai API Key (optional, Enter to skip)", "YELLOW_AI_API_KEY", "", True, False, True)
        set_env_var(state, "YELLOW_AI_API_KEY", yellow)

        if state.values.get("JAPI_KEY") == "YOUR_JAPI_KEY":
            state.values["JAPI_KEY"] = ""
        japi_key = ask(state, "JAPI Key (optional, Enter to skip)", "JAPI_KEY", "", True, False, True)
        set_env_var(state, "JAPI_KEY", japi_key)

        if state.values.get("JAPI_AUTHORIZATION") == "YOUR_JAPI_AUTHORIZATION":
            state.values["JAPI_AUTHORIZATION"] = ""
        japi_auth = ask(state, "JAPI Authorization (optional, Enter to skip)", "JAPI_AUTHORIZATION", "",
                        True, False, True)
        set_env_var(state, "JAPI_AUTHORIZATION", japi_auth)

    if not state.dry_run:
        state.config_file.chmod(0o600)
    state_mark_done(state, "generate_env")


def step_config_validate(state):
    if step_done("config_validate") and not state.fresh and not state.reconfigure:
        log("config_validate: already done, skipping")
        return
    log("Validating rendered compose configuration...")
    if state.dry_run and not which("docker"):
        print("[dry-run] docker isn't installed yet - skipping live 'compose config' validation")
        state_mark_done(state, "config_validate")
        return
    if compose(state, ["config", "-q"], check=False).returncode != 0:
        die("compose config validation failed - fix config.env and retry.")
    state_mark_done(state, "config_validate")


def step_build_and_start(state):
    if step_done("build_and_start") and not state.fresh and not state.reconfigure:
        log("build_and_start: already done, skipping")
        return

    app_image = state.values.get("APP_IMAGE", "")
    if app_image:
        os.environ["APP_IMAGE"] = app_image
        log(f"Using image {app_image} (skipping local build)")
    else:
        if compose(state, ["build", "webhook-app"], check=False).returncode != 0:
            die("image build failed (see output above) - fix the Dockerfile/build context and retry.")

    if compose(state, ["up", "-d"], check=False).returncode != 0:
        print("Start failed, reverting (docker compose down)...", file=sys.stderr)
        compose(state, ["down"], check=False)
        sys.exit(1)

    state_mark_done(state, "build_and_start")


# Prints what's needed to enable HTTPS once DNS is actually pointed here.
def print_ssl_todo(domain):
    print("  To enable HTTPS:")
    print(f"    1. Point a DNS A record for {domain} at this host's public IP.")
    print(f"    2. Verify it resolves:  dig +short {domain}")
    print(f"    3. Re-run:              {PROG} install")
    print("       (this only retries the certificate step - nothing else is redone)")


def step_ssl_cert(state):
    if state.ssl_mode != "managed":
        return
    if (SCRIPT_DIR / "nginx" / "ssl-enabled" / "nginx-https.conf").is_file():
        return
    if step_done("ssl_cert") and not state.fresh:
        log("ssl_cert: already done, skipping")
        return

    domain = re.sub(r"^https?://", "", state.external_url).split("/")[0]
    log(f"Requesting a Let's Encrypt certificate for {domain}...")
    if state.dry_run:
        print(f"[dry-run] would run: certbot certonly --webroot -w /var/www/certbot -d {domain}")
        print("[dry-run] would render nginx/ssl-enabled/nginx-https.conf and reload nginx")
        return

    certbot = compose(state, ["run", "--rm", "--entrypoint", "certbot", "certbot", "certonly", "--webroot",
                              "-w", "/var/www/certbot", "-d", domain, "--non-interactive", "--agree-tos",
                              "-m", f"admin@{domain}", "--no-eff-email"], check=False)
    if certbot.returncode == 0:
        render_template(
            SCRIPT_DIR / "nginx" / "nginx-https.conf.example",
            SCRIPT_DIR / "nginx" / "ssl-enabled" / "nginx-https.conf",
            {"EXTERNAL_DOMAIN": domain, "PORT": state.values.get("PORT", "8080"),
             "HTTPS_PORT": state.values.get("HTTPS_PORT", "443")},
        )
        if compose(state, ["exec", "nginx", "nginx", "-s", "reload"], check=False).returncode != 0:
            log("Warning: certificate issued, but nginx failed to reload it. Reload manually:")
            log(f"  docker compose --env-file {state.config_file} -f {state.compose_file} --profile ssl "
                "exec nginx nginx -s reload")
        state_mark_done(state, "ssl_cert")
        log(f"Certificate issued - {state.external_url} is now served over HTTPS.")
        return

    print(f"Warning: certificate issuance failed for {domain} (see certbot output above - usually DNS not "
          "pointing here yet).", file=sys.stderr)
    if state.non_interactive:
        log("Continuing over plain HTTP (--non-interactive: not prompting). Re-run 'install' once DNS is "
            "fixed to retry.")
    elif not confirm(state, "Continue running the app over plain HTTP for now (fix DNS and retry SSL later)?"):
        print(f"Aborting: fix DNS for {domain}, then re-run 'install' to retry.", file=sys.stderr)
        compose(state, ["down"], check=False)
        sys.exit(1)
    print()
    print_ssl_todo(domain)
    print()


def _app_healthy(port):
    url = f"http://127.0.0.1:{port}/"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status == 404
    except urllib.error.HTTPError as e:
        return e.code == 404
    except Exception:
        return False


def step_health_check(state):
    if step_done("health_check") and not state.fresh and not state.reconfigure:
        log("health_check: already done, skipping")
        return
    port = state.values.get("PORT", "8080")
    if state.dry_run:
        print(f"[dry-run] would poll http://127.0.0.1:{port}/ for readiness")
        state_mark_done(state, "health_check")
        return

    attempt, max_attempts = 0, 15
    while not _app_healthy(port):
        attempt += 1
        if attempt >= max_attempts:
            die(f"app did not become healthy on port {port} after {max_attempts} attempts.")
        time.sleep(2)
    log(f"App is up on port {port}")

    if state.ssl_mode == "managed":
        domain = re.sub(r"^https?://", "", state.external_url).split("/")[0]
        check_url = f"https://{domain}:{state.values.get('HTTPS_PORT', '443')}/"
        try:
            urllib.request.urlopen(check_url, timeout=5)
        except Exception:
            log(f"Warning: {check_url} not reachable yet (DNS/cert propagation can take a few minutes).")
    state_mark_done(state, "health_check")


def register_webhook(state):
    v = load_env_file(state.config_file)
    client_id = v.get("CLIENT_ID", "")
    client_secret = v.get("CLIENT_SECRET", "")
    api_key = v.get("API_KEY", "")
    signing_key = v.get("SIGNING_KEY", "")
    external_url = v.get("EXTERNAL_URL", "")

    print("Getting Auth Token")
    if not client_id or not client_secret or not api_key:
        print("Error: CLIENT_ID, CLIENT_SECRET, and API_KEY must be set in your config file")
        return False
    if not signing_key:
        print("Error: SIGNING_KEY must be set in your config file")
        return False

    login_body = json.dumps({"client_id": client_id, "client_secret": client_secret,
                             "api_key": api_key}).encode()
    auth_token = None
    try:
        req = urllib.request.Request("https://api.eka.care/connect-auth/v1/account/login",
                                     data=login_body, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            auth_token = json.loads(resp.read().decode()).get("access_token")
    except urllib.error.HTTPError as e:
        print(f"Auth request failed. HTTP Status: {e.code}")
        print(f"Response: {e.read().decode(errors='replace')}")
    except (urllib.error.URLError, ValueError) as e:
        print(f"Auth request failed: {e}")

    if not auth_token:
        print("Error: Failed to obtain auth token. Check your CLIENT_ID, CLIENT_SECRET, and API_KEY.")
        return False

    print(f"Registering webhook with URL: {external_url}")
    sub_body = json.dumps({
        "event_names": ["appointment.created", "appointment.updated",
                        "prescription.created", "prescription.updated"],
        "endpoint": external_url,
        "signing_key": signing_key,
        "protocol": "https",
    }).encode()
    try:
        req = urllib.request.Request(
            "https://api.eka.care/notification/v1/connect/webhook/subscriptions",
            data=sub_body,
            headers={"Authorization": f"Bearer {auth_token}", "Content-Type": "application/json"},
            method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, body = resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read().decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"Failed to register webhook: {e}")
        return False

    if 200 <= status < 300:
        print(f"Webhook registered successfully! (HTTP {status})")
        print(f"Response: {body}")
        return True
    print(f"Failed to register webhook. HTTP Status: {status}")
    print(f"Response: {body}")
    return False


def step_webhook_register(state):
    if state.skip_webhook_register:
        log(f"Skipping webhook registration (--skip-webhook-register). Register later with: "
            f"{PROG} register-webhook")
        return
    if step_done("webhook_register") and not state.fresh and not state.reconfigure:
        log("webhook_register: already done, skipping")
        return
    if state.dry_run:
        print("[dry-run] would call register_webhook() (POST to api.eka.care)")
        state_mark_done(state, "webhook_register")
        return

    attempt, max_attempts, delay = 0, 5, 5
    while not register_webhook(state):
        attempt += 1
        if attempt >= max_attempts:
            print(f"Error: webhook registration failed after {max_attempts} attempts.", file=sys.stderr)
            print(f"Fix the reported issue, then re-run: {PROG} register-webhook", file=sys.stderr)
            sys.exit(1)
        log(f"Retrying webhook registration in {delay}s (attempt {attempt + 1}/{max_attempts})...")
        time.sleep(delay)
        delay *= 2
    state_mark_done(state, "webhook_register")


def step_finalize(state):
    port = state.values.get("PORT", "8080")
    log("Deployment complete.")
    print(f"  URL:          {state.external_url or f'http://<this-host>:{port}'}")
    if state.ssl_mode == "managed":
        https_port = state.values.get("HTTPS_PORT", "443")
        if (SCRIPT_DIR / "nginx" / "ssl-enabled" / "nginx-https.conf").is_file():
            if https_port != "443":
                print(f"                (nginx is listening on non-standard HTTPS_PORT={https_port} - "
                      f"include it in the URL: {state.external_url}:{https_port})")
        else:
            ssl_domain = re.sub(r"^https?://", "", state.external_url).split("/")[0]
            print(f"  SSL:          not yet enabled - serving plain HTTP only on port "
                  f"{state.values.get('HTTP_PORT', '80')} for now.")
            print_ssl_todo(ssl_domain)
    print(f"  Config file:  {state.config_file}")
    profile_flag = "--profile ssl " if state.ssl_mode == "managed" else ""
    print(f"  View logs:    {PROG} status   (or) docker compose --env-file {state.config_file} "
          f"-f {state.compose_file} {profile_flag}logs -f webhook-app")
    print(f"  Upgrade:      {PROG} upgrade [--image <ref>]")
    print(f"  Uninstall:    {PROG} uninstall")


# ---- subcommands -------------------------------------------------------------

def load_config_file(state):
    if not state.config_file.exists():
        example = Path(str(state.config_file) + ".example")
        if not example.exists():
            die(f"neither {state.config_file} nor {example} found.")
        if state.dry_run:
            print(f"[dry-run] would create {state.config_file} from {example.name}")
        else:
            shutil.copy(example, state.config_file)
            state.config_file.chmod(0o600)
            log(f"Created {state.config_file.name} from {example.name}")
    state.values = load_env_file(state.config_file)


def resolve_ssl_mode(state):
    state.ssl_mode = state.cli_ssl_mode or state.values.get("SSL_MODE") or "external"


# Runs before anything else on install/upgrade: confirms the files this
# installer depends on are present and the env/nginx config is structurally
# sound, so a broken checkout fails immediately with a clear message.
def verify_setup(state):
    log("Verifying installer files and configuration...")
    missing = False
    required_files = [state.compose_file, SCRIPT_DIR / "Dockerfile",
                      SCRIPT_DIR / "nginx" / "nginx.conf.example",
                      SCRIPT_DIR / "nginx" / "nginx-https.conf.example"]
    for f in required_files:
        try:
            rel = f.relative_to(SCRIPT_DIR)
        except ValueError:
            rel = f
        if f.is_file():
            log(f"  OK       {rel}")
        else:
            log(f"  MISSING  {rel}")
            missing = True

    load_config_file(state)
    if state.config_file.exists():
        log(f"  OK       {state.config_file.name}")
    elif state.dry_run and Path(str(state.config_file) + ".example").exists():
        log(f"  OK       {state.config_file.name} (dry-run: would be created from .example)")
    else:
        log(f"  MISSING  {state.config_file.name}")
        missing = True

    if missing:
        die("this checkout is missing files the installer depends on - re-clone/restore the repo before "
            "continuing.")

    if not state.config_file.exists():
        log(f"  (dry-run) compose config validation skipped - {state.config_file.name} doesn't exist yet")
    elif which("docker") and compose_plugin_ok():
        resolve_ssl_mode(state)
        result = compose(state, ["config", "-q"], check=False, capture=True)
        if result.returncode == 0:
            log(f"  OK       {state.compose_file.name} + {state.config_file.name} render correctly")
        else:
            print(f"Error: {state.compose_file.name} / {state.config_file.name} failed to validate:",
                  file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            sys.exit(1)
    else:
        log("  Docker not installed yet - full compose config validation runs later (config_validate step)")


# Some users hand-craft config.env before running install. If it already
# existed before this run, show what's in it (secrets masked) and ask once
# whether to use it as-is - if so, ask() stops re-confirming already-set
# values field-by-field for the rest of this run (config_confirmed).
def confirm_existing_config(state):
    if state.non_interactive:
        return
    print()
    log(f"Found an existing {state.config_file.name} - here's what's configured:")
    secret_pattern = re.compile(r"(SECRET|KEY|TOKEN|PASSWORD|AUTH)")
    for line in state.config_file.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = _unquote(value.strip())
        if not value:
            display = "(blank)"
        elif secret_pattern.search(key):
            display = "(set)"
        else:
            display = value
        print(f"  {key}={display}")
    print()

    answer = input("Use this configuration as-is (skip per-field prompts, keep every value exactly as in "
                   "the file)? [Y/n]: ").strip()
    if answer.lower() != "n":
        log(f"Using {state.config_file.name} as-is for this run.")
        state.config_confirmed = True
        return

    state.reconfigure = True
    fields = input("Which field(s) do you want to change? (space/comma-separated names, e.g. "
                   "CLIENT_SECRET API_KEY - leave blank to review every field one by one): ").strip()
    if fields:
        state.fields_to_change = [f.upper() for f in re.split(r"[,\s]+", fields) if f]
        log(f"Only re-prompting for: {' '.join(state.fields_to_change)} - everything else keeps its value "
            f"from {state.config_file.name}.")
    else:
        log("Reviewing every field - Enter keeps the existing value, or type a new one.")


def cmd_install(state):
    config_pre_existed = state.config_file.exists()

    apply_skip_nginx(state)
    verify_setup(state)
    if config_pre_existed:
        confirm_existing_config(state)
    state_init(state)
    step_preflight(state)
    step_docker_install(state)
    step_network_create(state)
    step_ssl_setup(state)
    step_generate_env(state)
    warn_unmatched_fields_to_change(state)
    step_config_validate(state)
    step_build_and_start(state)
    step_ssl_cert(state)
    step_health_check(state)
    step_webhook_register(state)
    step_finalize(state)


def cmd_upgrade(state):
    apply_skip_nginx(state)
    verify_setup(state)
    state_init(state)
    if state.cli_image:
        state.values["APP_IMAGE"] = state.cli_image
    app_image = state.values.get("APP_IMAGE", "")
    if app_image:
        os.environ["APP_IMAGE"] = app_image
        set_env_var(state, "APP_IMAGE", app_image)
        log(f"Using image {app_image}")
    else:
        if compose(state, ["build", "webhook-app"], check=False).returncode != 0:
            die("image build failed (see output above) - fix the Dockerfile/build context and retry. The "
                "previous container, if any, is untouched.")
    if compose(state, ["up", "-d"], check=False).returncode != 0:
        print("Error: upgrade failed to start the new container (see output above).", file=sys.stderr)
        print("Not tearing anything down automatically - check 'docker compose ... ps' for current state, "
              "then fix the issue and retry.", file=sys.stderr)
        sys.exit(1)
    step_health_check(state)
    log("Upgrade complete.")


def cmd_stop(state):
    load_config_file(state)
    resolve_ssl_mode(state)
    if not state.non_interactive:
        if not confirm(state, "This stops and removes eka-webhook containers (volumes/certs/network are "
                              "kept). Continue?"):
            print("Aborted.")
            return
    if compose(state, ["down"], check=False).returncode != 0:
        die("'docker compose down' failed (see output above).")
    print("Containers stopped and removed. Config, volumes, certs, and the eka-net network were left in place.")
    print(f"Bring it back up with: {PROG} install   (or) {PROG} upgrade")


def cmd_uninstall(state):
    load_config_file(state)
    resolve_ssl_mode(state)
    if not state.non_interactive:
        if not confirm(state, "This stops and removes eka-webhook containers and named volumes. Continue?"):
            print("Aborted.")
            return
    if compose(state, ["down", "-v"], check=False).returncode != 0:
        die("'docker compose down -v' failed (see output above).")
    if not state.non_interactive:
        if confirm(state, "Also remove the docker network 'eka-net'?"):
            subprocess.run(["docker", "network", "rm", "eka-net"], capture_output=True)
    print(f"Note: {state.config_file} and {STATE_FILE} were left in place (they hold secrets/history) - "
          "remove manually if no longer needed.")


def cmd_status(state):
    if STATE_FILE.exists():
        print(f"Install state ({STATE_FILE}):")
        print(json.dumps(_load_state(), indent=2))
    else:
        print(f"No install state found at {STATE_FILE} (nothing installed yet?)")
    print()
    if state.config_file.exists():
        load_config_file(state)
        resolve_ssl_mode(state)
        compose(state, ["ps"], check=False)


def cmd_register_webhook(state):
    load_config_file(state)
    register_webhook(state)


# ---- entrypoint ------------------------------------------------------------------

def _enable_command_tracing():
    """--debug: trace every subprocess command before running it, the closest
    Python equivalent to bash's `set -x`."""
    real_run = subprocess.run

    def traced_run(cmd, *args, **kwargs):
        if isinstance(cmd, (list, tuple)):
            print(f"+ {' '.join(str(c) for c in cmd)}", file=sys.stderr)
        return real_run(cmd, *args, **kwargs)

    subprocess.run = traced_run


def _print_partial_config_hint(state):
    """On a failed/aborted install, point the user at the partial config so
    they can see exactly what they entered. Every answer is written the moment
    it's given (set_env_var), and nothing deletes the file on failure."""
    if state.action != "install" or state.dry_run or not state.config_file.exists():
        return
    print(f"\n[eka-deploy] Your answers so far are saved in {state.config_file} (chmod 600) - open it to "
          "see exactly what was entered.", file=sys.stderr)
    print(f"[eka-deploy] Fix whatever's flagged above (edit the file directly, or re-run and decline "
          f"'use as-is' to re-prompt), then run '{PROG} install' again - it resumes from where you "
          "stopped, keeping everything already answered.", file=sys.stderr)


def main():
    state = parse_args(sys.argv[1:])
    if state.debug:
        _enable_command_tracing()

    dispatch = {
        "install": cmd_install,
        "upgrade": cmd_upgrade,
        "stop": cmd_stop,
        "uninstall": cmd_uninstall,
        "status": cmd_status,
        "register-webhook": cmd_register_webhook,
    }
    try:
        dispatch[state.action](state)
    except SystemExit as e:
        if e.code not in (0, None):
            _print_partial_config_hint(state)
        raise
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        _print_partial_config_hint(state)
        sys.exit(130)
    except Exception:
        _print_partial_config_hint(state)
        raise


if __name__ == "__main__":
    main()
