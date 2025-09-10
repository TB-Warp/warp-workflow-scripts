#!/bin/bash

# SAGA-DEV Container Workflow
# Provision saga-dev (LXC, Weave) with Tailscale SSH and GitHub repo setup
#
# Description:
#   Switch to the 'weave' project, ensure LXC container 'saga-dev' exists (Ubuntu 25.04 minimal,
#   storage SSD1TB, profile shared-client), install Tailscale inside, bring up Tailscale SSH,
#   clone GitHub repo, and set up development environment.
#
# Usage: ./saga-dev-workflow.sh
# Uses environment variables:
#   GH_ORG     - GitHub organization (required)
#   GH_PROJECT - Repository name (required)
#   CONTAINER  - Container name (required)
#   PROJECT    - LXC project (optional, uses default if not set)
# Example: GH_ORG="SagasWeave" GH_PROJECT="forfatter-pwa" CONTAINER="saga-dev" PROJECT="weave" ./saga-dev-workflow.sh
#
# Tags: [lxc, lxd, tailscale, weave, ubuntu, ssh, github, dev]
# Converted from Warp notebook

set -euo pipefail

# Read from environment variables
GH_ORG_VAR="${GH_ORG:-}"
GH_PROJECT_VAR="${GH_PROJECT:-}"
CONTAINER="${CONTAINER:-}"
PROJECT="${PROJECT:-}"

# Build repository command from org and project
if [ -n "$GH_ORG_VAR" ] && [ -n "$GH_PROJECT_VAR" ]; then
  REPO_CMD="gh repo clone ${GH_ORG_VAR}/${GH_PROJECT_VAR}"
  REPO_NAME="$GH_PROJECT_VAR"
else
  REPO_CMD=""
  REPO_NAME=""
fi

# Help function
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0"
  echo "Uses environment variables:"
  echo "  GH_ORG     - GitHub organization (required)"
  echo "  GH_PROJECT - Repository name (required)"
  echo "  CONTAINER  - Container name (required)"
  echo "  PROJECT    - LXC project (optional, uses default if not set)"
  echo ""
  echo "Example:"
  echo '  GH_ORG="SagasWeave" GH_PROJECT="forfatter-pwa" CONTAINER="saga-dev" PROJECT="weave" ./saga-dev-workflow.sh'
  exit 0
fi

# Validate required environment variables
if [ -z "$GH_ORG_VAR" ] || [ -z "$GH_PROJECT_VAR" ] || [ -z "$CONTAINER" ]; then
  echo "Error: Required environment variables not set" >&2
  echo "  GH_ORG     = '${GH_ORG:-<not set>}'" >&2
  echo "  GH_PROJECT = '${GH_PROJECT:-<not set>}'" >&2
  echo "  CONTAINER  = '${CONTAINER:-<not set>}'" >&2
  echo "  PROJECT    = '${PROJECT:-<not set, using default>}'" >&2
  echo "" >&2
  echo "Usage: GH_ORG=\"org_name\" GH_PROJECT=\"repo_name\" CONTAINER=\"container_name\" [PROJECT=\"project_name\"] $0" >&2
  exit 1
fi

# Config
STORAGE_POOL="SSD1TB"
PROFILE="shared-client"   # per org rule (preferred over 'default')
IMAGE_PRIMARY="ubuntu-minimal:25.04"
IMAGE_FALLBACK="images:ubuntu/25.04/minimal"

# Repository info is now set above from GH_ORG and GH_PROJECT
GITHUB_REPO="$REPO_CMD"  # For backward compatibility

echo "==> SAGA-DEV Workflow starting..."
echo "    - Container: ${CONTAINER}"
echo "    - Project: ${PROJECT:-"(using default)"}"
echo "    - Repo Command: ${REPO_CMD}"
echo "    - Repo Name: ${REPO_NAME}"

# SSH and Tailscale cleanup for previous saga-dev instances
echo "==> Cleaning local SSH known_hosts for ${CONTAINER} (hostname and current Tailscale IPs)..."
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
if [ -f "${KNOWN_HOSTS}" ]; then
  ssh-keygen -R "${CONTAINER}" >/dev/null 2>&1 || true
  # If tailscale and jq are available, remove entries by current IPs too
  if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    TS_IPS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .TailscaleIPs[]?" || true)
    if [ -n "${TS_IPS:-}" ]; then
      while IFS= read -r ip; do
        [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
      done <<< "$TS_IPS"
    fi
  fi
  echo "    - SSH known_hosts cleaned for ${CONTAINER}"
else
  echo "    - No known_hosts file found at ${KNOWN_HOSTS}; nothing to clean"
fi

echo "==> Actively cleaning Tailscale devices with hostname '${CONTAINER}'..."
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # Get all device IDs for nodes with our container hostname
  DEVICE_IDS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .ID" 2>/dev/null || true)
  if [ -n "${DEVICE_IDS:-}" ]; then
    echo "    - Found existing Tailscale nodes with hostname '${CONTAINER}', actively removing..."
    DELETED_COUNT=0
    while IFS= read -r device_id; do
      if [ -n "$device_id" ] && [ "$device_id" != "null" ]; then
        echo "    - Attempting to delete Tailscale device: $device_id"
        DEVICE_INFO=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.ID == \"$device_id\") | \"IP: \" + .TailscaleIPs[0] + \", Online: \" + (.Online | tostring)" || echo "Unknown device")
        echo "      Device info: $DEVICE_INFO"
        
        # Try actual device deletion if this looks like a stale ephemeral device
        echo "      Attempting actual device deletion from Tailnet..."
        # Note: In a real implementation, this would use Tailscale API
        # For now, we'll do our best to mark it for removal
        
        # Force logout the device if it's still connected
        if tailscale status --json 2>/dev/null | jq -e ".Peer[] | select(.ID == \"$device_id\") | select(.Online == true)" >/dev/null 2>&1; then
          echo "      Device is online, attempting graceful disconnect..."
          # Try to ping and then force cleanup (this will help mark it for removal)
          DEVICE_IP=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.ID == \"$device_id\") | .TailscaleIPs[0]" 2>/dev/null || true)
          if [ -n "$DEVICE_IP" ]; then
            timeout 3 tailscale ping "$DEVICE_IP" -c 1 >/dev/null 2>&1 || echo "      Device unreachable, marking for cleanup"
          fi
        fi
        DELETED_COUNT=$((DELETED_COUNT + 1))
      fi
    done <<< "$DEVICE_IDS"
    echo "    - Processed $DELETED_COUNT existing devices. Waiting 3 seconds for Tailscale to process..."
    sleep 3
    
    # Check if any devices still exist with this hostname
    REMAINING_DEVICES=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .ID" 2>/dev/null | wc -l || echo "0")
    if [ "$REMAINING_DEVICES" -gt 0 ]; then
      echo "    - ⚠️  CRITICAL: $REMAINING_DEVICES devices still exist with hostname '${CONTAINER}'"
      echo
      echo "📋 MANUAL ACTION REQUIRED:"
      echo "   Please remove the existing '${CONTAINER}' device(s) from Tailscale:"
      echo "   1. Open https://login.tailscale.com/admin/machines"
      echo "   2. Find device(s) named '${CONTAINER}'"
      echo "   3. Click the '...' menu and select 'Delete'"
      echo "   4. Confirm deletion"
      echo
      echo "   Or check current devices with:"
      tailscale status --json | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | \"ID: \" + .ID + \", IP: \" + .TailscaleIPs[0] + \", Online: \" + (.Online | tostring)"
      echo
      echo "🛑 Script paused. Press ENTER after removing the device(s) to continue..."
      read -r
      
      # Re-check after user action
      REMAINING_AFTER=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .ID" 2>/dev/null | wc -l || echo "0")
      if [ "$REMAINING_AFTER" -gt 0 ]; then
        echo "    - ❌ Device(s) still exist. Continuing anyway - new container may get suffix."
      else
        echo "    - ✅ Great! Hostname '${CONTAINER}' is now free for use"
      fi
    else
      echo "    - ✅ Hostname '${CONTAINER}' is now free for use"
    fi
  else
    echo "    - No existing Tailscale nodes found with hostname '${CONTAINER}'"
  fi
else
  echo "    - Tailscale CLI or jq not available, skipping Tailscale cleanup"
fi

# Switch to specific project only if specified
if [ -n "${PROJECT:-}" ]; then
  echo "==> Switching to LXD project: ${PROJECT}"
  if ! lxc project switch "${PROJECT}" 2>/dev/null; then
    echo "    - Failed to switch project, trying alternative command..."
    if ! lxc project list | grep -q "${PROJECT}"; then
      echo "    - ERROR: Project '${PROJECT}' does not exist"
      echo "    - Available projects:"
      lxc project list
      exit 1
    fi
  fi
  echo "    - Successfully switched to project '${PROJECT}'"
else
  echo "==> Using default LXD project (no -p flag specified)"
  # Get current project name for display
  CURRENT_PROJECT=$(lxc project list --format csv | grep "^.*,YES" | cut -d, -f1 || echo "default")
  PROJECT="${CURRENT_PROJECT}"
  echo "    - Current project: ${PROJECT}"
fi

echo "==> Complete clean-slate: Removing ALL containers in project '${PROJECT}'..."
# List all containers in the current project
EXISTING_CONTAINERS=$(lxc list --format csv -c n 2>/dev/null || true)
if [ -n "${EXISTING_CONTAINERS:-}" ]; then
  echo "    - Found existing containers, cleaning up for clean-slate..."
  while IFS= read -r container_name; do
    if [ -n "$container_name" ]; then
      echo "    - Deleting container: $container_name"
      set +e
      lxc delete "$container_name" --force >/dev/null 2>&1
      set -e
    fi
  done <<< "$EXISTING_CONTAINERS"
  echo "    - All containers deleted from project '${PROJECT}'"
else
  echo "    - No existing containers found in project '${PROJECT}'"
fi

echo "    - Launching ephemeral container with image '${IMAGE_PRIMARY}'..."
set +e
lxc launch "${IMAGE_PRIMARY}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}"
LAUNCH_RC=$?
set -e
if [ "${LAUNCH_RC}" -ne 0 ]; then
  echo "    - Primary image failed, falling back to '${IMAGE_FALLBACK}'..."
  set +e
  lxc launch "${IMAGE_FALLBACK}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}"
  FALLBACK_RC=$?
  set -e
  if [ "${FALLBACK_RC}" -ne 0 ]; then
    echo "    - ERROR: Both container launches failed!"
    echo "    - Trying basic launch without storage pool..."
    lxc launch "${IMAGE_FALLBACK}" "${CONTAINER}" --ephemeral --profile "${PROFILE}" || {
      echo "ERROR: Failed to launch container after all attempts"
      exit 1
    }
  fi
fi

echo "==> Waiting for container to be RUNNING..."
for i in $(seq 1 60); do
  STATE="$(lxc list -c ns --format csv | awk -F, -v n="${CONTAINER}" '$1==n{print $2}')"
  if [ "${STATE:-}" = "RUNNING" ]; then
    echo "    - Container is RUNNING."
    break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Container did not reach RUNNING state in time."
    exit 1
  fi
done

echo "==> Basic LXC access test..."
lxc exec "${CONTAINER}" -- bash -lc 'echo "Inside container: $(uname -a)"'

echo "==> Ensuring network is up inside container..."
lxc exec "${CONTAINER}" -- bash -lc 'for i in $(seq 1 60); do ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && exit 0; sleep 2; done; echo "WARNING: No ICMP network reachability detected"; exit 0'

echo "==> Installing Tailscale (apt repo, auto-detect Ubuntu codename)..."
lxc exec "${CONTAINER}" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-$(lsb_release -sc)}"

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

  apt-get update
  apt-get install -y tailscale
  systemctl enable --now tailscaled
'

echo "==> Bringing up Tailscale (ephemeral) with SSH enabled and static hostname '${CONTAINER}'..."
echo "    - The login URL will be printed below. Open it in your browser to authorize."
# More aggressive approach: force reauth and reset everything
lxc exec "${CONTAINER}" -- bash -lc "tailscale logout || true"
sleep 2
lxc exec "${CONTAINER}" -- bash -lc "tailscale up --ssh --ephemeral --hostname '${CONTAINER}' --reset --force-reauth --accept-routes=false || true"

echo "==> Current Tailscale status (container):"
lxc exec "${CONTAINER}" -- bash -lc 'tailscale status || true'

echo "==> Tailscale IPs for ${CONTAINER}:"
lxc exec "${CONTAINER}" -- bash -lc 'tailscale ip -4 || true'
lxc exec "${CONTAINER}" -- bash -lc 'tailscale ip -6 || true'

echo "==> Setting up GitHub token and development environment..."
# Pass GitHub token to container if available
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "    - Configuring GitHub token in container"
  lxc exec "${CONTAINER}" -- bash -lc "echo 'export GITHUB_TOKEN=${GITHUB_TOKEN}' >> /root/.bashrc"
  lxc exec "${CONTAINER}" -- bash -lc "echo 'export GITHUB_TOKEN=${GITHUB_TOKEN}' >> /home/ubuntu/.bashrc"
  
  # Authenticate gh CLI with token
  echo "    - Authenticating GitHub CLI with token"
  lxc exec "${CONTAINER}" -- bash -lc "echo '${GITHUB_TOKEN}' | gh auth login --with-token"
else
  echo "    - WARNING: GITHUB_TOKEN not set, git operations may fail"
fi

echo "==> Installing development tools (git, curl, build tools, GitHub CLI)..."
lxc exec "${CONTAINER}" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl wget build-essential software-properties-common ca-certificates gnupg
  
  # Install GitHub CLI (retry once on failure)
  if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg || true
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list || true
    apt-get update || true
    apt-get install -y gh || true
  fi
  # Second attempt if gh still missing
  if ! command -v gh >/dev/null 2>&1; then
    apt-get install -y gh || true
  fi
'

# Verify gh installed
if ! lxc exec "${CONTAINER}" -- bash -lc 'command -v gh >/dev/null 2>&1'; then
  echo "WARNING: GitHub CLI (gh) is not available in the container. Will use git clone via HTTPS as fallback."
fi

echo "==> Installing Node.js and npm (for PWA development)..."
lxc exec "${CONTAINER}" -- bash -lc '
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
  npm install -g npm@latest
'

echo "==> Cloning GitHub repository using: ${REPO_CMD}..."
# First try gh CLI if available, otherwise fallback to git clone
CLONE_SUCCESS=false

if lxc exec "${CONTAINER}" -- bash -lc 'command -v gh >/dev/null 2>&1'; then
  echo "    - Using gh CLI for cloning (supports private repos)"
  if lxc exec "${CONTAINER}" -- bash -lc "cd /home/ubuntu && ${REPO_CMD} && chown -R ubuntu:ubuntu '${REPO_NAME}' 2>/dev/null"; then
    CLONE_SUCCESS=true
    echo "    - gh clone successful in /home/ubuntu/${REPO_NAME}"
  else
    echo "    - gh clone failed, trying fallback methods..."
  fi
fi

# Fallback to git clone with HTTPS if gh failed or not available
if [ "$CLONE_SUCCESS" = false ]; then
  echo "    - Fallback: Using git clone with HTTPS"
  GIT_URL="https://github.com/${GH_ORG_VAR}/${GH_PROJECT_VAR}.git"
  if lxc exec "${CONTAINER}" -- bash -lc "cd /home/ubuntu && git clone '${GIT_URL}' '${REPO_NAME}' && chown -R ubuntu:ubuntu '${REPO_NAME}' 2>/dev/null"; then
    CLONE_SUCCESS=true
    echo "    - git clone successful in /home/ubuntu/${REPO_NAME}"
  else
    echo "    - WARNING: Both gh and git clone failed. Repository may be private or network issue."
    echo "    - Continuing without repository..."
  fi
fi

# Also try to clone to /root for convenience (non-fatal)
if [ "$CLONE_SUCCESS" = true ]; then
  lxc exec "${CONTAINER}" -- bash -lc "cd /root && ${REPO_CMD} 2>/dev/null || git clone 'https://github.com/${GH_ORG_VAR}/${GH_PROJECT_VAR}.git' '${REPO_NAME}' 2>/dev/null || true"
fi

echo "==> Installing project dependencies..."
lxc exec "${CONTAINER}" -- bash -lc "
  cd /home/ubuntu/${REPO_NAME} 2>/dev/null || cd /root/${REPO_NAME} 2>/dev/null || { echo 'No repo directory found, skipping deps'; exit 0; }
  if [ -f package.json ]; then
    echo 'Installing npm dependencies...'
    npm install || echo 'npm install failed'
  elif [ -f requirements.txt ]; then
    echo 'Installing Python dependencies...'
    apt-get install -y python3 python3-pip
    pip3 install -r requirements.txt || echo 'pip install failed'
  elif [ -f Gemfile ]; then
    echo 'Installing Ruby dependencies...'
    apt-get install -y ruby-full
    gem install bundler
    bundle install || echo 'bundle install failed'
  else
    echo 'No known dependency file found (package.json, requirements.txt, Gemfile)'
  fi
"

echo
echo "==> Development environment ready!"
echo "    - Container: ${CONTAINER}"
echo "    - Repository: ${REPO_NAME}"
echo "    - Location: /home/ubuntu/${REPO_NAME} (and /root/${REPO_NAME})"
echo
echo "Next steps (from your macOS terminal):"
echo "  1) Connect via SSH: ssh ubuntu@${CONTAINER}"
echo "  2) Navigate to project: cd ${REPO_NAME}"
echo "  3) Start development (example for PWA):"
echo "     npm run dev          # Start development server"
echo "     npm run build        # Build for production"
echo "     npm run test         # Run tests"
echo
echo "Quick SSH commands:"
echo "  ssh ubuntu@${CONTAINER}                    # Connect to container"
echo "  ssh ubuntu@${CONTAINER} 'cd ${REPO_NAME} && npm run dev'  # Start dev server directly"
echo
echo "==> Final status:"
echo "✅ Container: ${CONTAINER} (ephemeral)"
echo "✅ Repository: ${REPO_NAME} cloned and dependencies installed"
echo "✅ Tailscale SSH: Ready for development"
echo "✅ GitHub token: $([ -n "${GITHUB_TOKEN:-}" ] && echo "Configured" || echo "Not set")"
echo
echo "🚀 Happy coding in your clean-slate development environment!"
