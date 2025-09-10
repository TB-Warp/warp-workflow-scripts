#!/bin/bash

# GitHub CLI Installation and Authentication
# Install gh CLI via brew and perform auth login
#
# Description:
#   Install GitHub CLI using brew (per org rule - never by other means on Mac)
#   Then perform gh auth login via GitHub browser authentication
#
# Tags: [github, cli, brew, auth, macos]

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

main() {
    log "Starting GitHub CLI installation and authentication"
    
    # Step 1: Check if brew is installed
    log "Checking if Homebrew is installed..."
    if ! command -v brew >/dev/null 2>&1; then
        log_error "Homebrew is not installed. Please install Homebrew first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    log_info "Homebrew is installed."

    # Step 2: Check if gh is already installed
    log "Checking if GitHub CLI is already installed..."
    if command -v gh >/dev/null 2>&1; then
        CURRENT_VERSION=$(gh --version | head -n1 | awk '{print $3}')
        log_info "GitHub CLI is already installed (version: ${CURRENT_VERSION})"
        
        # Ask if user wants to upgrade
        echo -n "Do you want to upgrade to the latest version? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log "Upgrading GitHub CLI..."
            brew upgrade gh
        else
            log_info "Skipping upgrade."
        fi
    else
        # Step 3: Install gh via brew
        log "Installing GitHub CLI via brew..."
        log_info "Per org rule: Local projects for Mac will be installed locally via brew never by other means."
        brew install gh
        log_info "GitHub CLI installed successfully."
    fi

    # Step 4: Check current auth status
    log "Checking current GitHub authentication status..."
    if gh auth status >/dev/null 2>&1; then
        log_info "Already authenticated to GitHub."
        
        # Show current status
        echo
        log "Current GitHub authentication status:"
        gh auth status
        echo
        
        # Ask if user wants to re-authenticate
        echo -n "Do you want to re-authenticate? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log "Authentication setup complete."
            return
        fi
    fi

    # Step 5: Perform authentication
    log "Starting GitHub authentication..."
    log_info "Per org rule: install gh and auth login via GitHub Browser."
    echo
    echo "You will be redirected to GitHub in your browser to complete authentication."
    echo "Please follow the instructions in your browser."
    echo
    
    # Use browser authentication (default)
    gh auth login --web
    
    # Step 6: Verify authentication
    log "Verifying authentication..."
    if gh auth status >/dev/null 2>&1; then
        log_info "Authentication successful!"
        echo
        log "GitHub authentication status:"
        gh auth status
        echo
        
        # Show user info
        log "Authenticated GitHub user:"
        gh api user --jq '.login + " (" + .name + ")"' || true
    else
        log_error "Authentication failed. Please try again."
        exit 1
    fi

    log "GitHub CLI installation and authentication completed successfully!"
    echo
    echo "You can now use GitHub CLI commands like:"
    echo "  gh repo list"
    echo "  gh issue list"
    echo "  gh pr list"
    echo "  gh repo create"
}

# Help function
show_help() {
    cat << EOF
GitHub CLI Installation and Authentication Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help          Show this help message
    --force-install     Force reinstall even if gh is already installed
    --skip-auth         Skip authentication step

DESCRIPTION:
    This script installs GitHub CLI via Homebrew and performs browser authentication.
    Following org rules:
    - Install via brew on Mac (never by other means)
    - Use GitHub browser authentication

EXAMPLES:
    $0                          # Install and authenticate
    $0 --skip-auth             # Install only, skip auth
    $0 --force-install         # Force reinstall

EOF
}

# Parse command line arguments
FORCE_INSTALL=false
SKIP_AUTH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --force-install)
            FORCE_INSTALL=true
            shift
            ;;
        --skip-auth)
            SKIP_AUTH=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Handle force install
if [ "$FORCE_INSTALL" = true ]; then
    log "Force install requested..."
    if command -v gh >/dev/null 2>&1; then
        brew uninstall gh
    fi
fi

# Handle skip auth
if [ "$SKIP_AUTH" = true ]; then
    log "Skipping authentication as requested."
    # Modify main function to skip auth steps
    main() {
        log "Starting GitHub CLI installation (auth skipped)"
        
        if ! command -v brew >/dev/null 2>&1; then
            log_error "Homebrew is not installed. Please install Homebrew first."
            exit 1
        fi
        
        if command -v gh >/dev/null 2>&1 && [ "$FORCE_INSTALL" = false ]; then
            log_info "GitHub CLI is already installed."
        else
            log "Installing GitHub CLI via brew..."
            brew install gh
        fi
        
        log "Installation completed. Run 'gh auth login' manually when ready."
    }
fi

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
