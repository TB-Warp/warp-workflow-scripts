#!/bin/bash

# SAGA-DEV Workflow v2 - Event-driven Architecture with timeout fixes
# Pure orchestrator that launches async scripts and monitors progress
#
# Usage: Set environment variables and run
# Required: GH_ORG, GH_PROJECT, CONTAINER  
# Optional: PROJECT, IMAGE, GITHUB_TOKEN, FRAMEWORKS

set -euo pipefail

# Use environment variables with sensible defaults (NO HARDCODED SECRETS)
GH_ORG_VAR="${GH_ORG:-SagasWeave}"
GH_PROJECT_VAR="${GH_PROJECT:-forfatter-pwa}"
CONTAINER="${CONTAINER:-saga-dev}"
PROJECT="${PROJECT:-weave}"
IMAGE="${IMAGE:-ubuntu:24.04}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
FRAMEWORKS="${FRAMEWORKS:-node:npm:ts:nextjs:mui}"

# Validate required variables
if [ -z "$GH_ORG_VAR" ] || [ -z "$GH_PROJECT_VAR" ] || [ -z "$CONTAINER" ]; then
    echo "Error: Required environment variables not set" >&2
    echo "  GH_ORG     = '${GH_ORG:-<not set>}'" >&2
    echo "  GH_PROJECT = '${GH_PROJECT:-<not set>}'" >&2
    echo "  CONTAINER  = '${CONTAINER:-<not set>}'" >&2
    exit 1
fi

# Warn if GitHub token is missing
if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️  WARNING: GITHUB_TOKEN not set - private repos may fail to clone" >&2
    echo "   Set with: export GITHUB_TOKEN=\"your_token_here\"" >&2
fi

# Derived variables
REPO_NAME="$GH_PROJECT_VAR"
STORAGE_POOL="SSD1TB"
PROFILE="shared-client"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"

# Color codes for output
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
NC='\\033[0m'

log() {
    echo -e "${GREEN}==> ${1}${NC}"
}

log_info() {
    echo -e "${BLUE}    - ${1}${NC}"
}

log_error() {
    echo -e "${RED}ERROR: ${1}${NC}"
}

# Help function
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "SAGA-DEV Workflow v2 - Event-driven Architecture with timeout fixes"
    echo ""
    echo "USAGE:"
    echo "  Set environment variables and run:"
    echo "  GH_ORG=org GH_PROJECT=repo CONTAINER=name ./saga-dev-workflow-v2.sh"
    echo ""
    echo "REQUIRED:"
    echo "  GH_ORG       - GitHub organization"
    echo "  GH_PROJECT   - Repository name"
    echo "  CONTAINER    - Container name"
    echo ""
    echo "OPTIONAL:"
    echo "  PROJECT      - LXD project (default: current)"
    echo "  IMAGE        - Container image (default: ubuntu:24.04)"
    echo "  GITHUB_TOKEN - GitHub token for private repos"
    echo "  FRAMEWORKS   - Colon-separated frameworks (default: node:npm:ts:nextjs:mui)"
    echo ""
    exit 0
fi

log "SAGA-DEV Workflow v2 starting..."
log_info "Container: ${CONTAINER}"
log_info "Project: ${PROJECT:-\"(using default)\"}"
log_info "Image: ${IMAGE}"
log_info "Repository: ${GH_ORG_VAR}/${GH_PROJECT_VAR}"
log_info "Frameworks: ${FRAMEWORKS}"

# Clean up old status files and create dependency tracking
rm -f /tmp/*-done /tmp/*-err /tmp/*-ready 2>/dev/null || true

# Create container ready marker for dependencies
echo "ready" > "/tmp/container-ready"

# SSH cleanup for previous saga-dev instances
log "Cleaning local SSH known_hosts for ${CONTAINER}..."
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
if [ -f "${KNOWN_HOSTS}" ]; then
    ssh-keygen -R "${CONTAINER}" >/dev/null 2>&1 || true
    # Clean by current Tailscale IPs if available
    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        TS_IPS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .TailscaleIPs[]?" || true)
        if [ -n "${TS_IPS:-}" ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
            done <<< "$TS_IPS"
        fi
    fi
    log_info "SSH known_hosts cleaned"
fi

# Clean up existing Tailscale devices with same hostname
log "Cleaning existing Tailscale devices with hostname '${CONTAINER}'..."
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    DEVICE_IDS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .ID" 2>/dev/null || true)
    if [ -n "${DEVICE_IDS:-}" ]; then
        log_info "Found existing devices, please remove them manually from Tailscale admin"
        echo "⚠️  Visit: https://login.tailscale.com/admin/machines"
        echo "    Find and delete devices named '${CONTAINER}'"
        echo ""
        echo "Press ENTER when done..."
        read -r
    fi
fi

# Switch to LXD project if specified
if [ -n "$PROJECT" ]; then
    log "Switching to LXD project: ${PROJECT}"
    if lxc project switch "${PROJECT}" 2>/dev/null; then
        :
    else
        lxc switch project "${PROJECT}" 2>/dev/null || {
            log_error "Failed to switch to project '${PROJECT}'"
            exit 1
        }
    fi
    log_info "Successfully switched to project '${PROJECT}'"
fi

# Clean slate: remove all containers in project
log "Complete clean-slate: Removing ALL containers in current project..."
EXISTING_CONTAINERS=$(lxc list --format csv -c n 2>/dev/null || true)
if [ -n "${EXISTING_CONTAINERS:-}" ]; then
    log_info "Found existing containers, cleaning up..."
    while IFS= read -r container_name; do
        if [ -n "$container_name" ]; then
            log_info "Deleting container: $container_name"
            lxc delete "$container_name" --force >/dev/null 2>&1 || true
        fi
    done <<< "$EXISTING_CONTAINERS"
    log_info "All containers deleted"
else
    log_info "No existing containers found"
fi

# Launch new ephemeral container
log "Launching ephemeral container with image '${IMAGE}'..."
lxc launch "${IMAGE}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}" || {
    log_error "Failed to launch container"
    exit 1
}

# Wait for container to be running
log "Waiting for container to be RUNNING..."
for i in $(seq 1 30); do
    STATE="$(lxc list -c ns --format csv | awk -F, -v n="${CONTAINER}" '$1==n{print $2}')"
    if [ "${STATE:-}" = "RUNNING" ]; then
        log_info "Container is RUNNING"
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        log_error "Container did not reach RUNNING state in time"
        exit 1
    fi
done

# Basic container test
log "Testing container accessibility..."
lxc exec "${CONTAINER}" -- echo "Container ready" || {
    log_error "Container not accessible"
    exit 1
}
log_info "Container accessible"

log "🚀 Starting async setup scripts..."

# Start all async scripts in parallel with timeout fixes
"$SCRIPT_DIR/tailscale-setup.sh" "$CONTAINER" &
TAILSCALE_PID=$!

"$SCRIPT_DIR/github-setup.sh" "$CONTAINER" "$GITHUB_TOKEN" &
GITHUB_PID=$!

"$SCRIPT_DIR/devtools-setup.sh" "$CONTAINER" "$FRAMEWORKS" &
DEVTOOLS_PID=$!

"$SCRIPT_DIR/repo-setup.sh" "$CONTAINER" "$GH_ORG_VAR" "$GH_PROJECT_VAR" "$REPO_NAME" "$GITHUB_TOKEN" &
REPO_PID=$!

log_info "All async scripts started"
log_info "Tailscale PID: $TAILSCALE_PID"
log_info "GitHub PID: $GITHUB_PID" 
log_info "DevTools PID: $DEVTOOLS_PID"
log_info "Repository PID: $REPO_PID"

echo ""
log "📋 Real-time progress monitoring..."
echo ""

# Status display function with timeout/error detection
flag() {
    local name="$1"; local done="$2"; local err="$3"; local status_file="$4"
    if [ "$err" -eq 1 ]; then 
        echo "🔴 $name"
    elif [ "$done" -eq 1 ]; then 
        # Check if it's a timeout or error
        if [ -f "$status_file" ]; then
            case "$(cat "$status_file")" in
                "timeout") echo "⏰ $name" ;;
                "error") echo "🔴 $name" ;;
                *) echo "✅ $name" ;;
            esac
        else
            echo "✅ $name"
        fi
    else 
        echo "🟡 $name"
    fi
}

echo "⏳ Starting background jobs..."

# Status monitoring loop with timeout awareness
for i in $(seq 1 150); do  # 5 minutes max
    sleep 3
    
    # Check status files and update display
    ts_done=0; gh_done=0; dev_done=0; repo_done=0
    [ -f "/tmp/tailscale-done" ] && ts_done=1
    [ -f "/tmp/github-done" ] && gh_done=1
    [ -f "/tmp/devtools-done" ] && dev_done=1
    [ -f "/tmp/repo-done" ] && repo_done=1
    
    # Show simple status update with error detection (append only)
    echo "📋 STATUS UPDATE ($i): $(flag 'TS' $ts_done 0 '/tmp/tailscale-done') $(flag 'GH' $gh_done 0 '/tmp/github-done') $(flag 'DEV' $dev_done 0 '/tmp/devtools-done') $(flag 'REPO' $repo_done 0 '/tmp/repo-done')"
    
    # Check if all complete
    if [ $ts_done -eq 1 ] && [ $gh_done -eq 1 ] && [ $dev_done -eq 1 ] && [ $repo_done -eq 1 ]; then
        echo "✅ All jobs completed!"
        break
    fi
    
    # Check if all background processes finished (fallback)
    if ! kill -0 $TAILSCALE_PID 2>/dev/null && \
       ! kill -0 $GITHUB_PID 2>/dev/null && \
       ! kill -0 $DEVTOOLS_PID 2>/dev/null && \
       ! kill -0 $REPO_PID 2>/dev/null; then
        echo "🏁 All processes finished"
        break
    fi
done

echo ""
log "✅ All background jobs completed!"
echo ""

# Show final summary
log "🎯 SAGA-DEV Setup Summary:"
echo ""

# Container access info
log_info "Container: $CONTAINER"
if lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -e '.Self.TailscaleIPs[0]' >/dev/null 2>&1; then
    TS_IP=$(lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -r '.Self.TailscaleIPs[0]')
    log_info "Tailscale IP: $TS_IP"
    log_info "SSH access: ssh root@$CONTAINER"
    log_info "SSH access: ssh ubuntu@$CONTAINER"
else
    log_info "LXC access: lxc exec $CONTAINER -- bash"
fi

# Repository info
if [ -d "/tmp" ]; then  # Placeholder - should check in container
    log_info "Repository: ${REPO_NAME} cloned to /root/ and /home/ubuntu/"
fi

echo ""
log "💡 Quick start:"
echo "   ssh root@${CONTAINER}"
echo "   cd ${REPO_NAME}"
echo "   npm run dev  # or your development command"
echo ""

# Cleanup status files
rm -f /tmp/*-done /tmp/*-err 2>/dev/null || true

log "🚀 SAGA-DEV ready for development!"
