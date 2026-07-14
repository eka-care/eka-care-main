#!/bin/bash
# Shared outbound-connectivity preflight helpers.
# Sourced by both deploy-aws.sh (AWS) and deploy-local.sh (bare metal/VM/local)
# so both scripts fail fast - with the exact unreachable host and reason -
# instead of dying deep inside a build/push/API call because a client
# firewall blocks an endpoint.

# Sets LAST_TCP_ERROR to bash's own /dev/tcp error text (e.g. "Name or
# service not known" for a DNS failure, "Connection refused", "Connection
# timed out") so callers can report exactly why an endpoint was unreachable,
# not just that it was.
check_tcp() {
    local host="$1" port="$2"
    LAST_TCP_ERROR=""
    local err status
    if command -v timeout >/dev/null 2>&1; then
        err=$(timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>&1 >/dev/null)
    else
        err=$(bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>&1 >/dev/null)
    fi
    status=$?
    LAST_TCP_ERROR=$(echo "$err" | sed -E 's/^bash: (line [0-9]+: )?//' | paste -sd '; ' -)
    return $status
}

# Retries a single endpoint with backoff before giving up - client firewalls
# often block outbound traffic, and a single flaky attempt shouldn't fail the
# whole run. Does not exit: returns 1 so the caller can check every endpoint
# and report all blocked ones together, not just the first.
check_connectivity() {
    local host="$1" port="$2" label="$3"
    local attempt=1 max=3 delay=3
    while true; do
        if check_tcp "$host" "$port"; then
            echo "[eka-deploy]   OK    $label ($host:$port)"
            return 0
        fi
        if [ "$attempt" -ge "$max" ]; then
            echo "[eka-deploy]   FAIL  $label ($host:$port) - unreachable after $max attempts${LAST_TCP_ERROR:+: $LAST_TCP_ERROR}"
            return 1
        fi
        echo "[eka-deploy]   ...   $label ($host:$port) unreachable${LAST_TCP_ERROR:+ ($LAST_TCP_ERROR)}, retrying in ${delay}s (attempt $((attempt + 1))/$max)"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}
