#!/bin/bash
# Tailscale Device Cleanup Module - Handle existing devices with target hostname
set -euo pipefail

CONTAINER="${1:-${CONTAINER:-}}"
if [ -z "$CONTAINER" ]; then
    echo "ERROR: CONTAINER name required"
    exit 1
fi

echo "==> Tailscale Cleanup: Checking for existing devices with hostname '${CONTAINER}'..."

if ! command -v tailscale >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "ℹ️  Tailscale CLI or jq not available, skipping cleanup"
    exit 0
fi

# Check for existing devices
DEVICE_IDS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"$CONTAINER\") | .ID" 2>/dev/null | wc -l || echo "0")

if [ "$DEVICE_IDS" -gt 0 ]; then
    echo "⚠️  CRITICAL: $DEVICE_IDS devices exist with hostname '${CONTAINER}'"
    echo
    echo "📋 MANUAL ACTION REQUIRED:"
    echo "   Please remove the existing '${CONTAINER}' device(s) from Tailscale:"
    echo "   1. Open https://login.tailscale.com/admin/machines"
    echo "   2. Find device(s) named '${CONTAINER}'"
    echo "   3. Click the '...' menu and select 'Delete'"
    echo "   4. Confirm deletion"
    echo
    echo "   Current devices with hostname '${CONTAINER}':"
    tailscale status --json | jq -r ".Peer[] | select(.HostName == \"$CONTAINER\") | \"ID: \" + .ID + \", IP: \" + .TailscaleIPs[0] + \", Online: \" + (.Online | tostring)"
    echo
    echo "🛑 Script paused. Press ENTER after removing the device(s) to continue..."
    read -r
    
    # Re-check after user action
    REMAINING=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"$CONTAINER\") | .ID" 2>/dev/null | wc -l || echo "0")
    if [ "$REMAINING" -gt 0 ]; then
        echo "❌ Device(s) still exist. Continuing anyway - new container may get suffix."
        exit 1  # Signal that cleanup wasn't successful
    else
        echo "✅ Great! Hostname '${CONTAINER}' is now free for use"
    fi
else
    echo "✅ Hostname '${CONTAINER}' is free for use"
fi

exit 0
