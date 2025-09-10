#!/bin/bash
# Development Tools Setup Script - Self-discovering and event-driven with timeout fixes
# Usage: ./devtools-setup.sh <container_name> <frameworks>

set -euo pipefail

CONTAINER="${1:-saga-dev}"
FRAMEWORKS="${2:-node:npm:ts}"

# Progress reporting function
progress() {
    local msg="$1"
    echo "[$(date '+%H:%M:%S')] DEVTOOLS: $msg" >&2
}

progress "Waiting for container to be accessible..."

# Wait for container to be running and accessible (max 60 seconds)
for i in $(seq 1 30); do
    if lxc exec "$CONTAINER" -- echo "ready" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        progress "⚠️ Timeout waiting for container accessibility"
        echo "timeout" > "/tmp/devtools-done"
        exit 1
    fi
    sleep 2
done

progress "Container accessible, starting development tools setup..."

# Install Node.js if requested
if echo "$FRAMEWORKS" | grep -q "node"; then
    progress "Setting up Node.js..."
    
    lxc exec "$CONTAINER" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    
    if ! command -v node >/dev/null 2>&1; then
        echo "Installing Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y -qq nodejs
    else
        echo "Node.js already installed: $(node --version)"
    fi
    '
    
    progress "Node.js ready: $(lxc exec "$CONTAINER" -- node --version)"
fi

# Install global npm packages if requested
if echo "$FRAMEWORKS" | grep -q "npm" && lxc exec "$CONTAINER" -- command -v npm >/dev/null 2>&1; then
    progress "Installing global npm packages..."
    
    # TypeScript
    if echo "$FRAMEWORKS" | grep -q "ts"; then
        lxc exec "$CONTAINER" -- npm install -g typescript @types/node tsx --silent 2>/dev/null || true
        progress "TypeScript installed"
    fi
    
    # Next.js CLI
    if echo "$FRAMEWORKS" | grep -q "nextjs"; then
        lxc exec "$CONTAINER" -- npm install -g create-next-app --silent 2>/dev/null || true
        progress "Next.js CLI installed"
    fi
fi

# Install Go if requested
if echo "$FRAMEWORKS" | grep -q "go"; then
    progress "Setting up Go..."
    
    lxc exec "$CONTAINER" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    
    if ! command -v go >/dev/null 2>&1; then
        echo "Installing Go..."
        apt-get update -qq
        apt-get install -y -qq golang-go
        
        # Set up Go environment for both users
        echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> /root/.bashrc
        echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> /home/ubuntu/.bashrc 2>/dev/null || true
    else
        echo "Go already installed: $(go version)"
    fi
    '
    
    progress "Go ready"
fi

# Install additional tools
progress "Installing additional development tools..."

lxc exec "$CONTAINER" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Essential development tools
apt-get update -qq
apt-get install -y -qq \
    build-essential \
    git \
    curl \
    wget \
    unzip \
    jq \
    tree \
    nano \
    vim \
    htop

# Python (often useful)
apt-get install -y -qq python3 python3-pip || true
'

progress "✅ Development tools setup complete"
echo "done" > "/tmp/devtools-done"
