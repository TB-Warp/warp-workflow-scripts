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

# LOGIN APPROACH: Create complete installation script to run inside container
cat > /tmp/gh_complete_setup.sh <<'EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Starting GitHub CLI installation inside container..."

# Check if already installed
if command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI already installed: $(gh --version | head -1)"
else
    echo "Installing GitHub CLI..."
    
    # Add GitHub CLI repository
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    
    # Install
    apt-get update -qq
    apt-get install -y -qq gh
    
    echo "GitHub CLI installed: $(gh --version | head -1)"
fi

# Configure authentication if token is available
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "Configuring GitHub authentication..."
    
    # Authenticate using the token (in container environment)
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || {
        echo "⚠️ GitHub authentication failed"
        exit 1
    }
    
    # Add token to shell environments
    echo "export GITHUB_TOKEN=$GITHUB_TOKEN" >> /root/.bashrc
    if [ -d /home/ubuntu ]; then
        echo "export GITHUB_TOKEN=$GITHUB_TOKEN" >> /home/ubuntu/.bashrc 2>/dev/null || true
        chown ubuntu:ubuntu /home/ubuntu/.bashrc 2>/dev/null || true
    fi
    
    # Verify authentication
    if gh auth status >/dev/null 2>&1; then
        echo "✅ GitHub authentication successful"
        gh auth status
    else
        echo "⚠️ GitHub authentication verification failed"
        exit 1
    fi
else
    echo "⚠️ No GITHUB_TOKEN environment variable found"
    echo "   GitHub CLI installed but not authenticated"
fi

echo "GitHub CLI setup completed successfully"
EOF

# Copy script to container
chmod +x /tmp/gh_complete_setup.sh
lxc file push /tmp/gh_complete_setup.sh "$CONTAINER/tmp/gh_setup.sh"

progress "Installing GitHub CLI using login approach..."

# LOGIN APPROACH: Execute script with proper environment
if [ -n "$GITHUB_TOKEN" ]; then
    # Execute with GITHUB_TOKEN environment variable set
    if lxc exec "$CONTAINER" --env GITHUB_TOKEN="$GITHUB_TOKEN" -- bash /tmp/gh_setup.sh; then
        progress "✅ GitHub CLI installed and authenticated successfully"
    else
        progress "❌ GitHub CLI setup failed"
        echo "error" > "/tmp/github-done"
        exit 1
    fi
else
    # Execute without token
    if lxc exec "$CONTAINER" -- bash /tmp/gh_setup.sh; then
        progress "✅ GitHub CLI installed (no authentication)"
    else
        progress "❌ GitHub CLI installation failed"
        echo "error" > "/tmp/github-done"
        exit 1
    fi
fi

# Cleanup
lxc exec "$CONTAINER" -- rm -f /tmp/gh_setup.sh
rm -f /tmp/gh_complete_setup.sh

progress "✅ GitHub CLI setup complete"
echo "done" > "/tmp/github-done"
