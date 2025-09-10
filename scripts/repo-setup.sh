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

# LOGIN APPROACH: Create repository clone script to run inside container
cat > /tmp/repo_clone_setup.sh <<'EOF'
#!/bin/bash
set -euo pipefail

echo "Starting repository clone inside container..."
echo "Target: ${GH_ORG}/${GH_PROJECT} -> ${REPO_NAME}"

# Clone repository to both user directories
for base_dir in "/root" "/home/ubuntu"; do
    dest="${base_dir}/${REPO_NAME}"
    echo "Processing directory: $dest"
    
    if [ -d "$dest" ]; then
        echo "Repository already exists at $dest"
        continue
    fi
    
    echo "Cloning to $dest..."
    cd "$base_dir"
    
    # Try different clone methods based on available tools and credentials
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        echo "Using GitHub CLI (authenticated)"
        if gh repo clone "${GH_ORG}/${GH_PROJECT}" "${REPO_NAME}" 2>/dev/null; then
            echo "✅ GitHub CLI clone successful"
        else
            echo "⚠️ GitHub CLI clone failed, trying git with token"
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                git clone "https://${GITHUB_TOKEN}@github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}" 2>/dev/null || {
                    echo "❌ Git clone with token failed"
                    continue
                }
            else
                echo "❌ No GitHub token available for fallback"
                continue
            fi
        fi
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "Using git clone with token"
        if git clone "https://${GITHUB_TOKEN}@github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}" 2>/dev/null; then
            echo "✅ Git clone with token successful"
        else
            echo "⚠️ Private repo clone failed, trying public"
            git clone "https://github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}" 2>/dev/null || {
                echo "❌ Public clone also failed"
                continue
            }
        fi
    else
        echo "Using public git clone"
        if git clone "https://github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}" 2>/dev/null; then
            echo "✅ Public clone successful"
        else
            echo "❌ Public clone failed - repository may be private"
            continue
        fi
    fi
    
    # Set ownership for ubuntu directory
    if [ "$base_dir" = "/home/ubuntu" ] && [ -d "$dest" ]; then
        chown -R ubuntu:ubuntu "$dest" 2>/dev/null || true
        echo "Updated ownership for ubuntu user"
    fi
    
    echo "✅ Repository available at $dest"
    
    # Install npm dependencies if package.json exists
    if [ -f "$dest/package.json" ] && command -v npm >/dev/null 2>&1; then
        echo "Installing npm dependencies in $dest..."
        cd "$dest"
        
        if npm ci 2>/dev/null || npm install 2>/dev/null; then
            echo "✅ npm dependencies installed"
            
            # Fix ownership for ubuntu
            if [ "$base_dir" = "/home/ubuntu" ]; then
                chown -R ubuntu:ubuntu . 2>/dev/null || true
            fi
        else
            echo "⚠️ npm install failed"
        fi
    fi
done

echo "Repository clone setup completed"
EOF

# Copy script to container
chmod +x /tmp/repo_clone_setup.sh
lxc file push /tmp/repo_clone_setup.sh "$CONTAINER/tmp/repo_clone.sh"

progress "Cloning repository using login approach..."

# LOGIN APPROACH: Execute with environment variables set
clone_env="GH_ORG=${GH_ORG} GH_PROJECT=${GH_PROJECT} REPO_NAME=${REPO_NAME}"
if [ -n "$GITHUB_TOKEN" ]; then
    clone_env="$clone_env GITHUB_TOKEN=${GITHUB_TOKEN}"
fi

if lxc exec "$CONTAINER" --env "$clone_env" -- bash /tmp/repo_clone.sh; then
    progress "✅ Repository clone completed successfully"
else
    progress "❌ Repository clone failed"
    echo "error" > "/tmp/repo-done"
    exit 1
fi

# Cleanup
lxc exec "$CONTAINER" -- rm -f /tmp/repo_clone.sh
rm -f /tmp/repo_clone_setup.sh

progress "✅ Repository clone complete"
echo "done" > "/tmp/repo-done"
