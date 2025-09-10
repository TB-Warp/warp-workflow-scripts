#!/bin/bash

# SSH Fix for Ephemeral LXC Containers
# Fix SSH issues when connecting to ephemeral containers via Tailscale
#
# Description:
#   When ephemeral LXC containers are recreated, they get new SSH host keys and
#   ephemeral Tailscale nodes get new IPs, causing SSH connection issues on macOS.
#   This script cleans up SSH known_hosts and provides connection helpers optimized
#   for ephemeral infrastructure.
#
# Tags: [ssh, lxc, tailscale, macos, known_hosts, ephemeral]

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}==> ${1}${NC}"
}

log_warn() {
    echo -e "${YELLOW}WARNING: ${1}${NC}"
}

log_error() {
    echo -e "${RED}ERROR: ${1}${NC}"
}

log_info() {
    echo -e "${BLUE}    - ${1}${NC}"
}

# Default container name
CONTAINER_NAME="saga-dev"

# Function to clean SSH known_hosts for ephemeral containers
clean_ssh_known_hosts() {
    local container="$1"
    local known_hosts="$HOME/.ssh/known_hosts"
    
    log "Cleaning SSH known_hosts for ephemeral container: ${container}"
    
    if [[ ! -f "$known_hosts" ]]; then
        log_info "No known_hosts file found, nothing to clean."
        return 0
    fi
    
    # Create backup before aggressive cleanup
    cp "$known_hosts" "${known_hosts}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Get current Tailscale IP for the container (if it exists)
    local current_ip
    if current_ip=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"${container}\") | .TailscaleIPs[0]" 2>/dev/null) && [[ -n "$current_ip" && "$current_ip" != "null" ]]; then
        log_info "Current Tailscale IP for ${container}: ${current_ip}"
        ssh-keygen -R "$current_ip" >/dev/null 2>&1 || true
        log_info "Removed SSH key entries for current IP: ${current_ip}"
    fi
    
    # Remove entries for the hostname
    ssh-keygen -R "$container" >/dev/null 2>&1 || true
    log_info "Removed SSH key entries for hostname: ${container}"
    
    # For ephemeral containers, aggressively clean ALL Tailscale IPs
    # since they're temporary and will be reassigned
    log_info "Aggressively cleaning ALL Tailscale IP entries (ephemeral mode)..."
    if grep -E "^100\.[0-9]+\.[0-9]+\.[0-9]+" "$known_hosts" >/dev/null 2>&1; then
        local temp_file
        temp_file=$(mktemp)
        # Remove ALL Tailscale IP entries (100.x.x.x range)
        grep -v -E "^100\.[0-9]+\.[0-9]+\.[0-9]+" "$known_hosts" > "$temp_file" || true
        mv "$temp_file" "$known_hosts"
        log_info "Removed ALL Tailscale IP entries (ephemeral cleanup)"
    fi
    
    # Also clean IPv6 Tailscale entries (fd7a: range)
    if grep -E "^fd7a:[0-9a-f:]+" "$known_hosts" >/dev/null 2>&1; then
        local temp_file
        temp_file=$(mktemp)
        grep -v -E "^fd7a:[0-9a-f:]+" "$known_hosts" > "$temp_file" || true
        mv "$temp_file" "$known_hosts"
        log_info "Removed ALL Tailscale IPv6 entries (ephemeral cleanup)"
    fi
}

# Function to test SSH connectivity
test_ssh_connection() {
    local container="$1"
    local user="${2:-ubuntu}"
    
    log "Testing SSH connection to ${user}@${container}..."
    
    # First check if container is reachable via Tailscale
    if ! tailscale ping "$container" -c 1 >/dev/null 2>&1; then
        log_error "Cannot ping ${container} via Tailscale. Is the container running and connected?"
        return 1
    fi
    
    log_info "Container is reachable via Tailscale"
    
    # Test SSH connection with options that work well for dynamic containers
    log_info "Testing SSH connection..."
    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=10 \
           -o BatchMode=yes \
           "${user}@${container}" \
           "echo 'SSH connection successful'" 2>/dev/null; then
        log_info "SSH connection test successful!"
        return 0
    else
        log_warn "SSH connection test failed"
        return 1
    fi
}

# Function to connect with proper SSH options
connect_ssh() {
    local container="$1"
    local user="${2:-ubuntu}"
    
    log "Connecting to ${user}@${container} with optimal settings for ephemeral containers..."
    
    # Use SSH options that work well with ephemeral containers
    exec ssh -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR \
             -o ConnectTimeout=10 \
             "${user}@${container}"
}

# Function to get container status and IPs
show_container_status() {
    local container="$1"
    
    log "Container status for: ${container}"
    
    # Check Tailscale status
    echo
    log_info "Tailscale status:"
    if tailscale status | grep -E "(^|[[:space:]])${container}([[:space:]]|$)" || true; then
        :
    else
        log_warn "Container ${container} not found in Tailscale status"
    fi
    
    # Get Tailscale IPs
    echo
    log_info "Tailscale IPs:"
    if command -v jq >/dev/null 2>&1; then
        tailscale status --json | jq -r ".Peer[] | select(.HostName == \"${container}\") | \"IPv4: \" + .TailscaleIPs[0] + \", IPv6: \" + (.TailscaleIPs[1] // \"N/A\")" 2>/dev/null || echo "No IPs found or jq error"
    else
        tailscale status | grep "$container" | awk '{print "IPs: " $1}' || echo "No IPs found"
    fi
    
    # Check if we can ping
    echo
    log_info "Network reachability:"
    if tailscale ping "$container" -c 1 >/dev/null 2>&1; then
        echo "✅ Container is reachable via Tailscale"
    else
        echo "❌ Container is NOT reachable via Tailscale"
    fi
}

# Function to create SSH config entry for ephemeral containers
create_ssh_config() {
    local container="$1"
    local user="${2:-ubuntu}"
    local ssh_config="$HOME/.ssh/config"
    
    log "Creating SSH config entry for ephemeral container access..."
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    
    # Backup existing config
    if [[ -f "$ssh_config" ]]; then
        cp "$ssh_config" "${ssh_config}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Remove existing entry for this container
    if [[ -f "$ssh_config" ]]; then
        sed -i.tmp "/^Host ${container}$/,/^$/d" "$ssh_config" 2>/dev/null || true
        rm -f "${ssh_config}.tmp" 2>/dev/null || true
    fi
    
    # Add new entry optimized for ephemeral containers
    cat >> "$ssh_config" << EOF

# Ephemeral container: ${container}
# Generated by fix-ssh-dynamic-containers.sh (ephemeral mode)
Host ${container}
    User ${user}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 3
    # Optimized for ephemeral connections
    TCPKeepAlive yes
    Compression yes

EOF
    
    chmod 600 "$ssh_config"
    log_info "SSH config entry created for ephemeral ${container}"
    echo "You can now connect using: ssh ${container}"
}

# Help function
show_help() {
    cat << EOF
SSH Fix for Ephemeral LXC Containers

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    clean [CONTAINER]       Clean SSH known_hosts for container (default: saga-dev)
    test [CONTAINER] [USER] Test SSH connection (default: saga-dev, ubuntu)
    connect [CONTAINER] [USER] Connect via SSH (default: saga-dev, ubuntu)
    status [CONTAINER]      Show container Tailscale status (default: saga-dev)
    config [CONTAINER] [USER] Create SSH config entry (default: saga-dev, ubuntu)
    fix [CONTAINER] [USER]  Full fix: clean + config + test (default: saga-dev, ubuntu)

OPTIONS:
    -h, --help              Show this help message

EXAMPLES:
    $0 clean                # Clean known_hosts for saga-dev
    $0 test                 # Test connection to ubuntu@saga-dev  
    $0 connect              # Connect to ubuntu@saga-dev
    $0 connect saga-dev root # Connect to root@saga-dev
    $0 fix                  # Full fix for saga-dev
    $0 status               # Show saga-dev status

DESCRIPTION:
    This script helps fix SSH issues when connecting to ephemeral LXC containers
    via Tailscale. When ephemeral containers are recreated, they get new SSH host
    keys and ephemeral Tailscale nodes get reassigned IPs, causing connection issues.
    
    EPHEMERAL MODE FEATURES:
    • Aggressively cleans ALL Tailscale IPs (100.x.x.x and fd7a:) from known_hosts
    • Optimized SSH config with keepalive and compression for temporary connections
    • Enhanced error handling for containers that may disappear during operation

EOF
}

# Main function
main() {
    local command="${1:-fix}"
    local container="${2:-$CONTAINER_NAME}"
    local user="${3:-ubuntu}"
    
    case "$command" in
        clean)
            clean_ssh_known_hosts "$container"
            ;;
        test)
            test_ssh_connection "$container" "$user"
            ;;
        connect)
            connect_ssh "$container" "$user"
            ;;
        status)
            show_container_status "$container"
            ;;
        config)
            create_ssh_config "$container" "$user"
            ;;
        fix)
            log "Running full SSH fix for ${user}@${container}..."
            clean_ssh_known_hosts "$container"
            create_ssh_config "$container" "$user"
            if test_ssh_connection "$container" "$user"; then
                log "✅ SSH fix completed successfully!"
                echo
                echo "You can now connect using:"
                echo "  ssh ${container}"
                echo "  ssh ${user}@${container}"
            else
                log_warn "SSH connection still has issues. Check container status:"
                show_container_status "$container"
            fi
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Check prerequisites
check_prerequisites() {
    if ! command -v tailscale >/dev/null 2>&1; then
        log_error "Tailscale CLI not found. Please install Tailscale."
        exit 1
    fi
    
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_error "ssh-keygen not found. This should be available on macOS."
        exit 1
    fi
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    # Default: run fix command
    check_prerequisites
    main "fix"
elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
else
    check_prerequisites
    main "$@"
fi
