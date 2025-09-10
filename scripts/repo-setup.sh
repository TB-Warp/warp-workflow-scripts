#!/bin/bash
# Repository Clone Script - Self-discovering and event-driven with timeout fixes
# Usage: ./repo-setup.sh <container_name> <gh_org> <gh_project> <repo_name> [github_token]

set -euo pipefail

CONTAINER="${1:-saga-dev}"
GH_ORG="${2:-}"
GH_PROJECT="${3:-}"
REPO_NAME="${4:-}"
GITHUB_TOKEN="${5:-}"

# Progress reporting function
progress() {
    local msg="$1"
    echo "[$(date '+%H:%M:%S')] REPOSITORY: $msg" >&2
}

# Validate inputs
if [ -z "$GH_ORG" ] || [ -z "$GH_PROJECT" ] || [ -z "$REPO_NAME" ]; then
    progress "⚠️ Missing required parameters (org/project/name)"
    echo "error" > "/tmp/repo-done"
    exit 1
fi

progress "Waiting for container to be accessible..."

# Wait for container to be running and accessible (max 60 seconds)
for i in $(seq 1 30); do
    if lxc exec "$CONTAINER" -- echo "ready" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        progress "⚠️ Timeout waiting for container accessibility"
        echo "timeout" > "/tmp/repo-done"
        exit 1
    fi
    sleep 2
done

progress "Container accessible, waiting for GitHub CLI..."

# Wait for GitHub CLI to be available (max 5 minutes)
for i in $(seq 1 60); do
    if lxc exec "$CONTAINER" -- command -v gh >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        progress "⚠️ GitHub CLI not available after 5 minutes, attempting fallback"
        # Try git clone without gh CLI
        if [ -n "$GITHUB_TOKEN" ]; then
            progress "Using git with token as fallback"
        else
            progress "No GitHub token, trying public clone"
        fi
        break
    fi
    progress "Waiting for GitHub CLI installation... ($i/60)"
    sleep 5
done

progress "GitHub CLI available, checking authentication..."

# Check if GitHub CLI is authenticated
AUTHENTICATED=false
if lxc exec "$CONTAINER" -- gh auth status >/dev/null 2>&1; then
    AUTHENTICATED=true
    progress "GitHub CLI authenticated, cloning via gh..."
else
    progress "GitHub CLI not authenticated, checking for token..."
fi

progress "Starting repository clone: ${GH_ORG}/${GH_PROJECT}"

# Clone repository to both user directories
for base_dir in "/root" "/home/ubuntu"; do
    dest="${base_dir}/${REPO_NAME}"
    
    lxc exec "$CONTAINER" -- bash -c "
        set -euo pipefail
        
        if [ -d '$dest' ]; then
            echo 'Repository already exists at $dest'
        else
            echo 'Cloning to $dest...'
            cd '$base_dir'
            
            if $AUTHENTICATED && command -v gh >/dev/null 2>&1; then
                # Use gh CLI (handles private repos automatically)
                gh repo clone '${GH_ORG}/${GH_PROJECT}' '${REPO_NAME}' 2>/dev/null || exit 1
            elif [ -n '${GITHUB_TOKEN}' ]; then
                # Use git with token
                git clone 'https://${GITHUB_TOKEN}@github.com/${GH_ORG}/${GH_PROJECT}.git' '${REPO_NAME}' 2>/dev/null || exit 1
            else
                # Try public clone
                git clone 'https://github.com/${GH_ORG}/${GH_PROJECT}.git' '${REPO_NAME}' 2>/dev/null || exit 1
            fi
            
            # Set ownership for ubuntu directory
            if [ '$base_dir' = '/home/ubuntu' ] && [ -d '$dest' ]; then
                chown -R ubuntu:ubuntu '$dest' 2>/dev/null || true
            fi
            
            echo 'Repository cloned successfully'
        fi
    " || {
        progress "⚠️ Failed to clone to $dest"
        continue
    }
    
    progress "✅ Repository available at $dest"
    
    # Install npm dependencies if package.json exists
    if lxc exec "$CONTAINER" -- test -f "$dest/package.json" && lxc exec "$CONTAINER" -- command -v npm >/dev/null 2>&1; then
        progress "Installing npm dependencies in $dest..."
        
        lxc exec "$CONTAINER" -- bash -c "
            cd '$dest'
            npm ci 2>/dev/null || npm install 2>/dev/null || echo 'npm install failed'
            
            # Fix ownership for ubuntu
            if [ '$base_dir' = '/home/ubuntu' ]; then
                chown -R ubuntu:ubuntu . 2>/dev/null || true
            fi
        " && progress "npm dependencies installed" || progress "⚠️ npm install failed"
    fi
done

progress "✅ Repository clone complete"
echo "done" > "/tmp/repo-done"
