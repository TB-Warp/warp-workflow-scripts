#!/bin/bash
# Tailscale Setup Script - Self-discovering and event-driven with timeout fixes
# Usage: ./tailscale-setup.sh <container_name>

set -euo pipefail

CONTAINER="${1:-saga-dev}"

# Progress reporting function
progress() {
    local msg="$1"
    echo "[$(date '+%H:%M:%S')] TAILSCALE: $msg" >&2
}

progress "Waiting for container to be accessible..."

# Wait for container to be running and accessible (max 60 seconds)
for i in $(seq 1 30); do
    if lxc info "$CONTAINER" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        progress "⚠️ Timeout waiting for container info"
        echo "timeout" > "/tmp/tailscale-done"
        exit 1
    fi
    sleep 2
done

for i in $(seq 1 30); do
    if lxc exec "$CONTAINER" -- echo "ready" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        progress "⚠️ Timeout waiting for container accessibility"
        echo "timeout" > "/tmp/tailscale-done"
        exit 1
    fi
    sleep 2
done

progress "Container accessible, checking network..."

# Wait for basic network connectivity (max 2 minutes)
for i in $(seq 1 24); do
    if lxc exec "$CONTAINER" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 24 ]; then
        progress "⚠️ Network timeout, continuing without connectivity check"
        break
    fi
    progress "Waiting for network connectivity... ($i/24)"
    sleep 5
done

progress "Network ready, starting Tailscale setup..."

# Install and configure Tailscale
lxc exec "$CONTAINER" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Check if already installed
if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale already installed"
else
    echo "Installing Tailscale..."
    
    # Get Ubuntu codename
    . /etc/os-release || true
    CODENAME="${VERSION_CODENAME:-noble}"
    
    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    
    # Add Tailscale repository
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    
    # Install Tailscale
    apt-get update -qq
    apt-get install -y -qq tailscale
    
    # Enable service
    systemctl enable --now tailscaled
fi

# Connect to Tailscale
tailscale up --ssh --hostname="'$CONTAINER'" --accept-routes=false 2>/dev/null || true
'

progress "Waiting for Tailscale connection..."

# Wait for Tailscale to be connected
for i in $(seq 1 30); do
    if lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -e '.Self.TailscaleIPs[0]' >/dev/null 2>&1; then
        TS_IP=$(lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -r '.Self.TailscaleIPs[0]')
        progress "✅ Connected (IP: $TS_IP)"
        echo "done" > "/tmp/tailscale-done"
        exit 0
    fi
    sleep 2
done

progress "⚠️ Connection timeout, but Tailscale is installed"
echo "timeout" > "/tmp/tailscale-done"
