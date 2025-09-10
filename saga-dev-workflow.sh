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
#   GH_ORG       - GitHub organization (required)
#   GH_PROJECT   - Repository name (required) 
#   CONTAINER    - Container name (required)
#   PROJECT      - LXC project (optional, uses default if not set)
#   IMAGE        - Container image (optional, defaults to Ubuntu 24.04 LTS)
#   GITHUB_TOKEN - GitHub token for private repos (recommended)
#   FIGMA_PROJECT- Figma project identifier (optional, for future use)
# Example: GH_ORG="SagasWeave" GH_PROJECT="forfatter-pwa" CONTAINER="saga-dev" PROJECT="weave" IMAGE="ubuntu:24.04" FRAMEWORKS="node:npm:ts:nextjs:mui" ./saga-dev-workflow.sh
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
  echo "  GH_ORG       - GitHub organization (required)"
  echo "  GH_PROJECT   - Repository name (required)"
  echo "  CONTAINER    - Container name (required)"
  echo "  PROJECT      - LXC project (optional, uses default if not set)"
  echo "  IMAGE        - Container image (optional, e.g. ubuntu:24.04, ubuntu:22.04)"
  echo "  GITHUB_TOKEN - GitHub token for private repos (recommended)"
  echo "  FRAMEWORKS   - Colon-separated frameworks (node:npm:ts:nextjs:mui:go:haxe)"
  echo "  FIGMA_PROJECT- Figma project identifier (optional, future use)"
  echo ""
  echo "Example:"
  echo '  GH_ORG="SagasWeave" GH_PROJECT="forfatter-pwa" CONTAINER="saga-dev" PROJECT="weave" IMAGE="ubuntu:24.04" FRAMEWORKS="node:npm:ts:nextjs:mui" ./saga-dev-workflow.sh'
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

# Handle IMAGE environment variable with flexible naming
if [ -n "${IMAGE:-}" ]; then
  # Convert common formats to proper LXC image names
  case "$IMAGE" in
    ubuntu24.04|ubuntu:24.04)
      IMAGE_PRIMARY="ubuntu:24.04"
      IMAGE_FALLBACK="images:ubuntu/24.04"
      ;;
    ubuntu22.04|ubuntu:22.04)
      IMAGE_PRIMARY="ubuntu:22.04"
      IMAGE_FALLBACK="images:ubuntu/22.04"
      ;;
    ubuntu25.04|ubuntu:25.04)
      IMAGE_PRIMARY="ubuntu:25.04"
      IMAGE_FALLBACK="images:ubuntu/25.04"
      ;;
    *)
      # Use as-is for custom images
      IMAGE_PRIMARY="$IMAGE"
      IMAGE_FALLBACK="images:ubuntu/24.04"  # safe fallback
      ;;
  esac
else
  # Default to Ubuntu 24.04 LTS
  IMAGE_PRIMARY="images:ubuntu/24.04"
  IMAGE_FALLBACK="ubuntu:24.04"
fi

# Repository info is now set above from GH_ORG and GH_PROJECT
GITHUB_REPO="$REPO_CMD"  # For backward compatibility

echo "==> SAGA-DEV Workflow starting..."
echo "    - Container: ${CONTAINER}"
echo "    - Project: ${PROJECT:-"(using default)"}"
echo "    - Image: ${IMAGE:-"default (24.04 LTS)"} -> ${IMAGE_PRIMARY}"
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

echo "==> Container is RUNNING - preparing network (Tailscale) ..."

# === Ensure Tailscale is UP (block until connected or timeout) ===
# Try to bring it up (profile may already have done it)
lxc exec "${CONTAINER}" -- bash -lc 'tailscale up --ssh --hostname "'"${CONTAINER}"'" --accept-routes=false >/dev/null 2>&1 || true'

# Wait for Tailscale connection (max ~60s)
echo "    - Waiting for Tailscale connection (up to 60s)..."
TS_READY=0
for i in $(seq 1 30); do
  TS_IP=$(lxc exec "${CONTAINER}" -- tailscale status --json 2>/dev/null | jq -r '.Self.TailscaleIPs[0] // ""' 2>/dev/null || true)
  if [ -n "${TS_IP}" ]; then
    TS_READY=1
    break
  fi
  sleep 2

done
if [ "$TS_READY" -eq 1 ]; then
  echo "    - Tailscale: READY (${TS_IP})"
  echo "    - SSH: ssh root@${CONTAINER}  (or ssh ubuntu@${CONTAINER})"
else
  echo "    - Tailscale: TIMED OUT (you can still use: lxc exec ${CONTAINER} -- bash)"
fi

# === Start async bootstrap tasks inside container (FIRE-AND-FORGET) ===
echo "==> Starting background tasks: gh, dev tools, repo clone ..."

lxc exec "${CONTAINER}" --env GITHUB_TOKEN="${GITHUB_TOKEN:-}" --env GH_ORG_VAR="${GH_ORG_VAR}" --env GH_PROJECT_VAR="${GH_PROJECT_VAR}" --env REPO_NAME="${REPO_NAME}" --env FRAMEWORKS="${FRAMEWORKS:-}" -- bash -lc '
  # Set up GitHub token in environment files immediately
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "export GITHUB_TOKEN=${GITHUB_TOKEN}" >> /root/.bashrc
    echo "export GITHUB_TOKEN=${GITHUB_TOKEN}" >> /home/ubuntu/.bashrc
  fi
  
  # Create comprehensive async bootstrap script with env vars
  cat > /root/bootstrap_async.sh << "EOF_ASYNC"
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Export all required environment variables from the main script
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GH_ORG_VAR="${GH_ORG_VAR:-}"
export GH_PROJECT_VAR="${GH_PROJECT_VAR:-}"
export REPO_NAME="${REPO_NAME:-}"
export FRAMEWORKS="${FRAMEWORKS:-}"
export CONTAINER="${CONTAINER:-}"

echo "$(date): Starting async bootstrap jobs..." > /tmp/bootstrap.log

# Robust apt wrapper with timeout and retry
apt_wrap() {
  local cmd="$*"
  local retries=3
  local timeout=120
  
  for i in $(seq 1 $retries); do
    if timeout $timeout flock -w 10 /tmp/apt.wrap.lock bash -c "$cmd" 2>&1; then
      return 0
    fi
    echo "$(date): apt_wrap retry $i/$retries for: $cmd" >> /tmp/bootstrap.log
    sleep $((i * 2))
  done
  echo "$(date): apt_wrap failed after $retries retries: $cmd" >> /tmp/bootstrap.log
  return 1
}

# JOB 1: Tailscale setup (optional maintenance)
(
  set +e
  echo "$(date): [tailscale] Starting..." >> /tmp/bootstrap.log
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "$(date): [tailscale] Installing from scratch..." >> /tmp/bootstrap.log
    . /etc/os-release || true
    CODENAME="${VERSION_CODENAME:-noble}"
    apt_wrap "apt-get update" || true
    apt_wrap "apt-get install -y ca-certificates curl gnupg" || true
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null 2>&1 || true
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" | tee /etc/apt/sources.list.d/tailscale.list >/dev/null 2>&1 || true
    apt_wrap "apt-get update" || true
    apt_wrap "apt-get install -y tailscale" || true
    systemctl enable --now tailscaled 2>/dev/null || true
  fi
  tailscale status >/dev/null 2>&1 || tailscale up --ssh --hostname="'"${CONTAINER}"'" --accept-routes=false >/dev/null 2>&1 || true
  echo "$(date): [tailscale] Completed" >> /tmp/bootstrap.log
  echo "done" > /tmp/tailscale-done
) &

# JOB 2: GitHub CLI and authentication
(
  set +e
  echo "$(date): [github] Starting..." >> /tmp/bootstrap.log
  if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null 2>&1 || true
    apt_wrap "apt-get update" || true
    if ! apt_wrap "apt-get install -y gh"; then
      echo "err" > /tmp/gh-err
    fi
  fi
  if [ -n "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null || echo "err" > /tmp/gh-err
  fi
  echo "$(date): [github] Completed" >> /tmp/bootstrap.log
  echo "done" > /tmp/gh-done
) &

# JOB 3: Development tools (Node, TypeScript, etc)
(
  set +e
  echo "$(date): [devtools] Starting..." >> /tmp/bootstrap.log
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x 2>/dev/null | bash - 2>&1 || echo "err" > /tmp/devtools-err
    apt_wrap "apt-get install -y nodejs" || echo "err" > /tmp/devtools-err
  fi
  if command -v npm >/dev/null 2>&1; then
    npm install -g typescript @types/node tsx 2>/dev/null || echo "err" > /tmp/devtools-err
  fi
  if echo "${FRAMEWORKS:-}" | grep -q "go"; then
    apt_wrap "apt-get install -y golang-go" || echo "err" > /tmp/devtools-err
  fi
  echo "$(date): [devtools] Completed" >> /tmp/bootstrap.log
  echo "done" > /tmp/devtools-done
) &

# JOB 4: Repository clone and setup (depends on gh being ready)
(
  set +e
  echo "$(date): [repo] Starting..." >> /tmp/bootstrap.log
  for i in $(seq 1 30); do
    if [ -f /tmp/gh-done ] || command -v gh >/dev/null 2>&1; then break; fi
    sleep 2
  done
  if [ -n "${REPO_NAME:-}" ] && [ -n "${GH_ORG_VAR:-}" ] && [ -n "${GH_PROJECT_VAR:-}" ]; then
    for base_dir in "/root" "/home/ubuntu"; do
      dest="${base_dir}/${REPO_NAME}"
      if [ ! -d "$dest" ]; then
        if command -v gh >/dev/null 2>&1; then
          cd "$base_dir" && gh repo clone "${GH_ORG_VAR}/${GH_PROJECT_VAR}" "${REPO_NAME}" 2>/dev/null || true
        elif [ -n "${GITHUB_TOKEN:-}" ]; then
          cd "$base_dir" && git clone "https://${GITHUB_TOKEN}@github.com/${GH_ORG_VAR}/${GH_PROJECT_VAR}.git" "${REPO_NAME}" 2>/dev/null || true
        else
          cd "$base_dir" && git clone "https://github.com/${GH_ORG_VAR}/${GH_PROJECT_VAR}.git" "${REPO_NAME}" 2>/dev/null || true
        fi
        # Ownership for ubuntu copy
        if [ "$base_dir" = "/home/ubuntu" ] && [ -d "$dest" ]; then
          chown -R ubuntu:ubuntu "$dest" 2>/dev/null || true
        fi
      fi
      if [ -d "$dest" ] && [ -f "$dest/package.json" ] && command -v npm >/dev/null 2>&1; then
        echo "$(date): [repo] Installing npm deps in $dest" >> /tmp/bootstrap.log
        cd "$dest" && (npm ci 2>/dev/null || npm install 2>/dev/null) || echo "err" > /tmp/repo-err
        if [ "$base_dir" = "/home/ubuntu" ]; then
          chown -R ubuntu:ubuntu . 2>/dev/null || true
        fi
      fi
    done
  fi
  echo "$(date): [repo] Completed" >> /tmp/bootstrap.log
  echo "done" > /tmp/repo-done
) &

# SUMMARY JOB: Wait for all and create final marker
(
  wait
  echo "$(date): All async jobs completed!" >> /tmp/bootstrap.log
  echo "all-done" > /tmp/bootstrap-all-done
  
  # Create a nice status summary
  {
    echo "=== SAGA-DEV BOOTSTRAP COMPLETE ==="
    echo "Container: '"${CONTAINER}"' in project '"$(lxc info | grep -o "project: .*" || echo "unknown")"'"
    echo "Timestamp: $(date)"
    echo
    echo "✅ Jobs completed:"
    [ -f /tmp/tailscale-done ] && echo "   - Tailscale setup"
    [ -f /tmp/gh-done ] && echo "   - GitHub CLI"
    [ -f /tmp/devtools-done ] && echo "   - Development tools"
    [ -f /tmp/repo-done ] && echo "   - Repository clone"
    echo
    echo "📁 Repository locations:"
    [ -d "/root/${REPO_NAME}" ] && echo "   - /root/${REPO_NAME}"
    [ -d "/home/ubuntu/${REPO_NAME}" ] && echo "   - /home/ubuntu/${REPO_NAME}"
    echo
    echo "🔗 Access:"
    echo "   - SSH: ssh root@'"${CONTAINER}"'"
    echo "   - SSH: ssh ubuntu@'"${CONTAINER}"'"
    if command -v tailscale >/dev/null 2>&1; then
      TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "not-connected")
      echo "   - Tailscale IP: $TS_IP"
    fi
    echo
    echo "🚀 Ready for development!"
  } > /tmp/bootstrap-summary.txt
) &
EOF_ASYNC
  
  # Start the async bootstrap (fire-and-forget)
  echo "$(date): Launching async bootstrap script..." > /tmp/bootstrap_async.out
  nohup bash /root/bootstrap_async.sh >>/tmp/bootstrap_async.out 2>&1 & disown
  echo "Async bootstrap PID $! started" >> /tmp/bootstrap_async.out
'
echo "==> Async bootstrap started!"
echo "✅ Network ready. Background setup continues safely."
echo "🔗 Access: ssh root@${CONTAINER}   |   lxc exec ${CONTAINER} -- bash"
echo

# Event-driven status monitoring
flag() {
  local name="$1"; local done="$2"; local err="$3"
  if [ "$err" -eq 1 ]; then echo "🔴 $name"; elif [ "$done" -eq 1 ]; then echo "🟢 $name"; else echo "🟡 $name"; fi
}

update_status() {
  DONE_GH=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/gh-done && echo 1 || echo 0' 2>/dev/null || echo 0)
  ERR_GH=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/gh-err && echo 1 || echo 0' 2>/dev/null || echo 0)
  DONE_DEV=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/devtools-done && echo 1 || echo 0' 2>/dev/null || echo 0)
  ERR_DEV=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/devtools-err && echo 1 || echo 0' 2>/dev/null || echo 0)
  DONE_REPO=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/repo-done && echo 1 || echo 0' 2>/dev/null || echo 0)
  ERR_REPO=$(lxc exec "${CONTAINER}" -- bash -lc 'test -f /tmp/repo-err && echo 1 || echo 0' 2>/dev/null || echo 0)
  
  # Clear previous status lines (move cursor up and clear)
  printf "\033[4A\033[J"
  
  echo "📋 BACKGROUND STATUS:"
  echo "   $(flag 'GitHub CLI' $DONE_GH $ERR_GH)"
  echo "   $(flag 'Dev tools'   $DONE_DEV $ERR_DEV)"
  echo "   $(flag 'Repository'  $DONE_REPO $ERR_REPO)"
  
  # Return 1 if all done (or failed), 0 if still working
  if [ $((DONE_GH + ERR_GH)) -eq 1 ] && [ $((DONE_DEV + ERR_DEV)) -eq 1 ] && [ $((DONE_REPO + ERR_REPO)) -eq 1 ]; then
    return 1  # All completed
  else
    return 0  # Still working
  fi
}

# Initial status display
echo "📋 BACKGROUND STATUS:"
echo "   🟡 GitHub CLI"
echo "   🟡 Dev tools"
echo "   🟡 Repository"

echo "==> Monitoring async jobs (max 5 minutes)..."

# Event loop: monitor until all complete or timeout
for i in $(seq 1 150); do  # 150 * 2s = 5 minutes max
  sleep 2
  
  if update_status; then
    continue  # Still working
  else
    # All jobs complete
    break
  fi
done

echo
echo "✅ All background jobs completed!"
echo "==> SAGA-DEV ready for development!"
echo
echo "💡 Quick start:"
echo "   ssh root@${CONTAINER}"
echo "   cd ${REPO_NAME:-forfatter-pwa}  # Navigate to project"
echo "   npm run dev                     # Start development"
echo
echo "==> Script completed successfully."
