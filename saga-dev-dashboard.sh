#!/bin/bash

# SAGA-DEV Traffic Light Dashboard
# Clean, real-time status monitoring for container setup

# Force bash even if called from zsh
if [ -n "${ZSH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

# Config from environment
CONTAINER="${CONTAINER:-saga-dev}"
PROJECT="${PROJECT:-weave}"
GH_ORG="${GH_ORG:-}"
GH_PROJECT="${GH_PROJECT:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
REPO_NAME="${GH_PROJECT}"

# Traffic light colors
RED="🔴"
YELLOW="🟡"
GREEN="🟢"
CLEAR_SCREEN="\033[2J\033[H"
CLEAR_LINE="\033[2K"

# Status tracking (bash 4+ associative array)
if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
    declare -A status
    status[container]="starting"
    status[network]="pending"
    status[github]="pending"
    status[devtools]="pending"
    status[repository]="pending"
    status[dependencies]="pending"
else
    echo "Error: Requires bash 4+ for associative arrays"
    exit 1
fi

# Get traffic light for status
light() {
    case "$1" in
        "starting"|"pending") echo "$YELLOW" ;;
        "done"|"ready") echo "$GREEN" ;;
        "error"|"failed") echo "$RED" ;;
        *) echo "$YELLOW" ;;
    esac
}

# Display clean dashboard
show_dashboard() {
    printf "$CLEAR_SCREEN"
    echo "SAGA-DEV Setup Status"
    echo "──────────────────────"
    echo
    echo "$(light ${status[container]}) Container Launch"
    echo "$(light ${status[network]}) Tailscale Network"
    echo "$(light ${status[github]}) GitHub CLI"
    echo "$(light ${status[devtools]}) Development Tools"
    echo "$(light ${status[repository]}) Repository Clone"
    echo "$(light ${status[dependencies]}) Dependencies Install"
    echo
    
    # Action messages
    if [[ "${status[network]}" == "auth_needed" ]]; then
        echo "⚠️  Action needed: Authorize Tailscale in browser"
    elif [[ "${status[network]}" == "device_conflict" ]]; then
        echo "⚠️  Action needed: Remove 'saga-dev' from Tailscale admin panel"
        echo "   https://login.tailscale.com/admin/machines"
    elif [[ "${status[container]}" == "ready" && "${status[network]}" == "ready" ]]; then
        echo "✅ Network ready: ssh root@$CONTAINER"
    fi
    
    # Completion check
    local all_done=true
    for s in "${status[@]}"; do
        if [[ "$s" != "done" && "$s" != "ready" ]]; then
            all_done=false
            break
        fi
    done
    
    if $all_done; then
        echo
        echo "🎉 All systems ready!"
        echo "   ssh root@$CONTAINER"
        echo "   cd $REPO_NAME && npm run dev"
        return 0  # Signal completion
    fi
    
    return 1  # Still working
}

# Check container status
check_container() {
    if lxc list -f csv -c n | grep -q "^$CONTAINER$"; then
        local state=$(lxc list -f csv -c ns | grep "^$CONTAINER," | cut -d, -f2)
        if [[ "$state" == "RUNNING" ]]; then
            status[container]="ready"
        else
            status[container]="starting"
        fi
    else
        status[container]="starting"
    fi
}

# Check network (Tailscale) status
check_network() {
    if [[ "${status[container]}" != "ready" ]]; then
        status[network]="pending"
        return
    fi
    
    # Check if tailscale is installed and connected
    if lxc exec "$CONTAINER" -- command -v tailscale >/dev/null 2>&1; then
        local ts_ip=$(lxc exec "$CONTAINER" -- tailscale status --json 2>/dev/null | jq -r '.Self.TailscaleIPs[0] // ""' 2>/dev/null || echo "")
        if [[ -n "$ts_ip" ]]; then
            status[network]="ready"
        else
            # Check if auth is needed
            if lxc exec "$CONTAINER" -- tailscale status 2>&1 | grep -q "authenticate"; then
                status[network]="auth_needed"
            else
                status[network]="starting"
            fi
        fi
    else
        status[network]="starting"
    fi
}

# Check async job status in container
check_async_jobs() {
    if [[ "${status[container]}" != "ready" ]]; then
        return
    fi
    
    # GitHub CLI
    if lxc exec "$CONTAINER" -- test -f /tmp/gh-done 2>/dev/null; then
        status[github]="done"
    elif lxc exec "$CONTAINER" -- test -f /tmp/gh-err 2>/dev/null; then
        status[github]="failed"
    fi
    
    # Dev tools
    if lxc exec "$CONTAINER" -- test -f /tmp/devtools-done 2>/dev/null; then
        status[devtools]="done"
    elif lxc exec "$CONTAINER" -- test -f /tmp/devtools-err 2>/dev/null; then
        status[devtools]="failed"
    fi
    
    # Repository
    if lxc exec "$CONTAINER" -- test -f /tmp/repo-done 2>/dev/null; then
        status[repository]="done"
    elif lxc exec "$CONTAINER" -- test -f /tmp/repo-err 2>/dev/null; then
        status[repository]="failed"
    fi
    
    # Dependencies (check if npm install completed)
    if lxc exec "$CONTAINER" -- test -d "/root/$REPO_NAME/node_modules" 2>/dev/null; then
        status[dependencies]="done"
    fi
}

# Start container and async jobs (minimal, quiet)
bootstrap() {
    # Switch project quietly
    lxc project switch "$PROJECT" 2>/dev/null || true
    
    # Clean slate - remove existing container
    lxc delete "$CONTAINER" --force 2>/dev/null || true
    
    # Launch container
    status[container]="starting"
    lxc launch ubuntu:24.04 "$CONTAINER" --profile shared-client >/dev/null 2>&1 &
    
    # Wait a moment for container to be running
    for i in $(seq 1 30); do
        check_container
        if [[ "${status[container]}" == "ready" ]]; then
            break
        fi
        sleep 1
    done
    
    # Start async bootstrap inside container
    if [[ "${status[container]}" == "ready" ]]; then
        lxc exec "$CONTAINER" --env GITHUB_TOKEN="$GITHUB_TOKEN" --env GH_ORG="$GH_ORG" --env GH_PROJECT="$GH_PROJECT" --env REPO_NAME="$REPO_NAME" -- bash -c '
            # Create async bootstrap script
            cat > /tmp/bootstrap.sh << "EOF"
#!/bin/bash
set +e  # Don'\''t exit on errors

# Tailscale setup
if ! command -v tailscale >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main" | tee /etc/apt/sources.list.d/tailscale.list
    apt-get update && apt-get install -y tailscale
    systemctl enable --now tailscaled
fi
tailscale up --ssh --hostname="'$CONTAINER'" --accept-routes=false || true

# GitHub CLI
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list
    apt-get update && apt-get install -y gh
fi
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "${GITHUB_TOKEN}" | gh auth login --with-token || echo "err" > /tmp/gh-err
fi
echo "done" > /tmp/gh-done

# Dev tools
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
fi
npm install -g typescript @types/node tsx || echo "err" > /tmp/devtools-err
echo "done" > /tmp/devtools-done

# Repository
if [ -n "${REPO_NAME:-}" ] && [ -n "${GH_ORG:-}" ] && [ -n "${GH_PROJECT:-}" ]; then
    cd /root
    if command -v gh >/dev/null 2>&1; then
        gh repo clone "${GH_ORG}/${GH_PROJECT}" "${REPO_NAME}" || git clone "https://github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}"
    else
        git clone "https://github.com/${GH_ORG}/${GH_PROJECT}.git" "${REPO_NAME}"
    fi
    if [ -d "${REPO_NAME}" ] && [ -f "${REPO_NAME}/package.json" ]; then
        cd "${REPO_NAME}" && npm install
    fi
fi
echo "done" > /tmp/repo-done
EOF

            # Start bootstrap in background
            nohup bash /tmp/bootstrap.sh >/dev/null 2>&1 &
        ' >/dev/null 2>&1
    fi
}

# Main event loop
main() {
    echo "Starting SAGA-DEV..."
    bootstrap
    
    # Traffic light monitoring loop
    while true; do
        check_container
        check_network
        check_async_jobs
        
        if show_dashboard; then
            break  # All done
        fi
        
        sleep 2
    done
}

# Trap cleanup
trap 'printf "\n"; exit' INT TERM

main "$@"
