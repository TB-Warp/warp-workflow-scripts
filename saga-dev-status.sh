#!/bin/bash

# SAGA-DEV Status Checker
# Quick status overview of saga-dev container and async jobs

CONTAINER="${1:-saga-dev}"

echo "🔍 SAGA-DEV STATUS: $CONTAINER"
echo

# Container status
if lxc list -f csv -c n | grep -q "^$CONTAINER$"; then
  STATE=$(lxc list -f csv -c ns | grep "^$CONTAINER," | cut -d, -f2)
  echo "📦 Container: $STATE"
else
  echo "❌ Container: Not found"
  exit 1
fi

# Tailscale network status (most important)
echo "🌐 Tailscale Network:"
if lxc exec "$CONTAINER" -- command -v tailscale >/dev/null 2>&1; then
  TS_STATUS=$(lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -r '.Self.TailscaleIPs[0] // "not-connected"' 2>/dev/null || echo "not-connected")
  if [ "$TS_STATUS" != "not-connected" ]; then
    echo "   ✅ Connected: $TS_STATUS"
    echo "   🔗 SSH: ssh root@$CONTAINER"
  else
    echo "   ⏳ Connecting... (may need browser auth)"
    echo "   📡 Direct: lxc exec $CONTAINER -- bash"
  fi
else
  echo "   ⏳ Installing..."
fi

# Quick async job status
echo
echo "⚙️  Background Jobs:"
DONE_JOBS=$(lxc exec "$CONTAINER" -- bash -c 'ls /tmp/*-done 2>/dev/null | wc -l')
if [ "$DONE_JOBS" -gt 0 ]; then
  echo "   ✅ Completed: $DONE_JOBS jobs"
  lxc exec "$CONTAINER" -- bash -c 'ls /tmp/*-done 2>/dev/null | sed "s/.*\///;s/-done//" | sed "s/^/      - /"'
else
  echo "   ⏳ Still working..."
fi

# Repository status
echo
echo "📁 Repository:"
if lxc exec "$CONTAINER" -- test -d "/root/forfatter-pwa" 2>/dev/null; then
  echo "   ✅ Cloned: /root/forfatter-pwa"
  if lxc exec "$CONTAINER" -- test -d "/root/forfatter-pwa/node_modules" 2>/dev/null; then
    echo "   ✅ Dependencies: Installed"
  else
    echo "   ⏳ Dependencies: Installing..."
  fi
else
  echo "   ⏳ Cloning..."
fi

echo
echo "💡 Quick access: ssh root@$CONTAINER || lxc exec $CONTAINER -- bash"
