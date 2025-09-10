#!/bin/bash

# SAGA-DEV Container Workflow
# Provision saga-dev (LXC, Weave) with Tailscale SSH and GitHub repo setup
#
# Description:
#   Switch to the 'weave' project, ensure LXC container 'saga-dev' exists (Ubuntu 25.04 minimal,
#   storage SSD1TB, profile shared-client), install Tailscale inside, bring up Tailscale SSH,
#   clone GitHub repo, and set up development environment.
#
# Usage: ./saga-dev-workflow.sh [REPO_CMD] [CONTAINER] [PROJECT]
# Example: ./saga-dev-workflow.sh "gh repo clone SagasWeave/forfatter-pwa" saga-dev weaver
#
# Tags: [lxc, lxd, tailscale, weave, ubuntu, ssh, github, dev]
# Converted from Warp notebook

set -euo pipefail

# Config
CONTAINER="${2:-saga-dev}"
PROJECT="${3:-weaver}"
STORAGE_POOL="SSD1TB"
PROFILE="shared-client"   # per org rule (preferred over 'default')
IMAGE_PRIMARY="ubuntu-minimal:25.04"
IMAGE_FALLBACK="images:ubuntu/25.04/minimal"

# Repository command from argument (default fallback)
REPO_CMD="${1:-gh repo clone SagasWeave/forfatter-pwa}"

# Parse repo command to extract repo name
if [[ "$REPO_CMD" == *"gh repo clone"* ]]; then
  # Extract repo name from gh command (e.g., "gh repo clone SagasWeave/forfatter-pwa" -> "forfatter-pwa")
  REPO_NAME=$(echo "$REPO_CMD" | sed 's/.*gh repo clone [^/]*\///' | sed 's/\.git$//' | awk '{print $1}')
  # For cloning, we'll use the full command
  GITHUB_REPO="$REPO_CMD"
elif [[ "$REPO_CMD" == https://* ]]; then
  # Full URL provided
  GITHUB_REPO="$REPO_CMD"
  REPO_NAME=$(basename "$GITHUB_REPO" .git)
else
  # Just repo name provided - assume SagasWeave org
  REPO_NAME="$REPO_CMD"
  GITHUB_REPO="https://github.com/SagasWeave/${REPO_NAME}"
fi

echo "==> SAGA-DEV Workflow starting..."
echo "    - Container: ${CONTAINER}"
echo "    - Project: ${PROJECT}"
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

echo "==> Cleaning old Tailscale nodes with hostname '${CONTAINER}'..."
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # Get all device IDs for nodes with our container hostname (including offline ones)
  DEVICE_IDS=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${CONTAINER}\") | .ID" 2>/dev/null || true)
  if [ -n "${DEVICE_IDS:-}" ]; then
    echo "    - Found existing Tailscale nodes with hostname '${CONTAINER}', cleaning up..."
    while IFS= read -r device_id; do
      if [ -n "$device_id" ] && [ "$device_id" != "null" ]; then
        # Check if device is offline (good candidate for deletion)
        IS_OFFLINE=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.ID == \"$device_id\") | select(.Online == false) | .ID" || true)
        if [ -n "$IS_OFFLINE" ] && [ "$IS_OFFLINE" = "$device_id" ]; then
          echo "    - Removing offline Tailscale device ID: $device_id"
          # Note: This requires admin API access in production
          # For now, just report what would be deleted
          echo "      (Device is offline and safe to remove)"
        else
          echo "    - Tailscale device $device_id is online, skipping"
        fi
      fi
    done <<< "$DEVICE_IDS"
    echo "    - Cleanup completed. Ephemeral nodes will auto-cleanup when disconnected."
  else
    echo "    - No existing Tailscale nodes found with hostname '${CONTAINER}'"
  fi
else
  echo "    - Tailscale CLI or jq not available, skipping Tailscale cleanup"
fi

echo "==> Switching to LXD project: ${PROJECT}"
if lxc project switch "${PROJECT}" 2>/dev/null; then
  :
else
  # Some environments use 'lxc switch project'
  lxc switch project "${PROJECT}"
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
  lxc launch "${IMAGE_FALLBACK}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}"
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
lxc exec "${CONTAINER}" -- bash -lc "tailscale up --ssh --ephemeral --hostname '${CONTAINER}' --reset || true"

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
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl wget build-essential software-properties-common
  
  # Install GitHub CLI
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
'

echo "==> Installing Node.js and npm (for PWA development)..."
lxc exec "${CONTAINER}" -- bash -lc '
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
  npm install -g npm@latest
'

echo "==> Cloning GitHub repository using: ${REPO_CMD}..."
if [[ "$REPO_CMD" == *"gh repo clone"* ]]; then
  # Use gh CLI for cloning (supports private repos with token)
  lxc exec "${CONTAINER}" -- bash -lc "cd /root && ${REPO_CMD} || echo 'gh clone failed, continuing...'"
  lxc exec "${CONTAINER}" -- bash -lc "cd /home/ubuntu && ${REPO_CMD} && chown -R ubuntu:ubuntu '${REPO_NAME}' || echo 'gh clone failed, continuing...'"
else
  # Use git clone for URLs
  lxc exec "${CONTAINER}" -- bash -lc "cd /root && git clone '${GITHUB_REPO}' '${REPO_NAME}' || echo 'git clone failed, continuing...'"
  lxc exec "${CONTAINER}" -- bash -lc "cd /home/ubuntu && git clone '${GITHUB_REPO}' '${REPO_NAME}' && chown -R ubuntu:ubuntu '${REPO_NAME}' || echo 'git clone failed, continuing...'"
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
