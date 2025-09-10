#!/bin/bash
# SSH Cleanup Module - Clean SSH known_hosts for container hostname
set -euo pipefail

CONTAINER="${1:-${CONTAINER:-}}"
if [ -z "$CONTAINER" ]; then
    echo "ERROR: CONTAINER name required"
    exit 1
fi

echo "==> SSH Cleanup: Cleaning known_hosts for ${CONTAINER}..."

KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
if [ -f "$KNOWN_HOSTS" ]; then
    ssh-keygen -R "$CONTAINER" >/dev/null 2>&1 || true
    
    # Clean Tailscale IPs if available
    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        TS_IPS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"$CONTAINER\") | .TailscaleIPs[]?" || true)
        if [ -n "${TS_IPS:-}" ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
            done <<< "$TS_IPS"
        fi
    fi
    echo "✅ SSH known_hosts cleaned for ${CONTAINER}"
else
    echo "ℹ️  No known_hosts file found"
fi

exit 0
