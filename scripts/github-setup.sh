#!/bin/bash
# GitHub CLI Setup Script - Self-discovering and event-driven with timeout fixes
# Usage: ./github-setup.sh <container_name> <github_token>

set -euo pipefail

CONTAINER="${1:-saga-dev}"
GITHUB_TOKEN="${2:-}"

# Progress reporting function
progress() {
    local msg="$1"
    echo "[$(date '+%H:%M:%S')] GITHUB: $msg" >&2
}

progress "Waiting for container to be accessible..."

# Wait for container to be running and accessible (max 60 seconds)
for i in $(seq 1 30); do
    if lxc exec "$CONTAINER" -- echo "ready" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        progress "⚠️ Timeout waiting for container accessibility"
        echo "timeout" > "/tmp/github-done"
        exit 1
    fi
    sleep 2
done

progress "Container accessible, waiting for basic tools..."

# Wait for curl to be available (max 2 minutes) or install it
for i in $(seq 1 24); do
    if lxc exec "$CONTAINER" -- command -v curl >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 24 ]; then
        progress "Installing curl as dependency..."
        lxc exec "$CONTAINER" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl' || {
            progress "⚠️ Failed to install curl, cannot continue"
            echo "error" > "/tmp/github-done"
            exit 1
        }
        break
    fi
    progress "Waiting for curl... ($i/24)"
    sleep 5
done

progress "Starting GitHub CLI installation..."

# Install GitHub CLI
lxc exec "$CONTAINER" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Check if already installed
if command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI already installed"
else
    echo "Installing GitHub CLI..."
    
    # Add GitHub CLI repository
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    
    # Install
    apt-get update -qq
    apt-get install -y -qq gh
fi
'

if [ -n "$GITHUB_TOKEN" ]; then
    progress "Configuring GitHub authentication..."
    
    # Configure authentication
    lxc exec "$CONTAINER" -- bash -c "
        echo '$GITHUB_TOKEN' | gh auth login --with-token 2>/dev/null || true
        
        # Add token to environment files
        echo 'export GITHUB_TOKEN=$GITHUB_TOKEN' >> /root/.bashrc
        echo 'export GITHUB_TOKEN=$GITHUB_TOKEN' >> /home/ubuntu/.bashrc 2>/dev/null || true
    "
    
    # Verify authentication
    if lxc exec "$CONTAINER" -- gh auth status >/dev/null 2>&1; then
        progress "✅ Authenticated successfully"
    else
        progress "⚠️ Authentication failed, but CLI installed"
    fi
else
    progress "⚠️ No GitHub token provided, CLI installed but not authenticated"
fi

progress "✅ GitHub CLI setup complete"
echo "done" > "/tmp/github-done"
