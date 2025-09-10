#!/bin/bash
# SAGA-DEV Modular Workflow - Resilient development environment setup
# Uses modular scripts with timeout-based fault tolerance
set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default timeout for modules (20 seconds of no output = abort)
MODULE_TIMEOUT="${MODULE_TIMEOUT:-20}"

# Read environment variables
GH_ORG_VAR="${GH_ORG:-}"
GH_PROJECT_VAR="${GH_PROJECT:-}"
CONTAINER="${CONTAINER:-}"
PROJECT="${PROJECT:-}"
IMAGE="${IMAGE:-ubuntu:24.04}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
FRAMEWORKS="${FRAMEWORKS:-}"
FIGMA_PROJECT="${FIGMA_PROJECT:-}"

# Validation
if [ -z "$GH_ORG_VAR" ] || [ -z "$GH_PROJECT_VAR" ] || [ -z "$CONTAINER" ]; then
    echo "ERROR: Required environment variables not set"
    echo "  GH_ORG     = '${GH_ORG:-<not set>}'"
    echo "  GH_PROJECT = '${GH_PROJECT:-<not set>}'"
    echo "  CONTAINER  = '${CONTAINER:-<not set>}'"
    echo
    echo "Usage: GH_ORG=\"org\" GH_PROJECT=\"repo\" CONTAINER=\"name\" [PROJECT=\"proj\"] [IMAGE=\"ubuntu:24.04\"] [FRAMEWORKS=\"node:npm:ts\"] $0"
    exit 1
fi

REPO_CMD="gh repo clone ${GH_ORG_VAR}/${GH_PROJECT_VAR}"
REPO_NAME="$GH_PROJECT_VAR"

echo "🚀 SAGA-DEV Modular Workflow starting..."
echo "    - Container: ${CONTAINER}"
echo "    - Project: ${PROJECT:-\"(using default)\"}"
echo "    - Image: ${IMAGE}"
echo "    - Repo: ${GH_ORG_VAR}/${GH_PROJECT_VAR}"
echo "    - Frameworks: ${FRAMEWORKS:-\"(auto-detect)\"}"
echo "    - Module Timeout: ${MODULE_TIMEOUT}s"
echo

# Module execution function
run_module() {
    local module="$1"
    local description="$2"
    shift 2
    local args=("$@")
    
    echo "📦 Running module: $description"
    
    if [ ! -f "$SCRIPT_DIR/scripts/$module" ]; then
        echo "❌ Module $module not found, skipping"
        return 1
    fi
    
    if "$SCRIPT_DIR/scripts/_runner.sh" "$MODULE_TIMEOUT" -- "$SCRIPT_DIR/scripts/$module" "${args[@]}"; then
        echo "✅ Module $description completed successfully"
        return 0
    else
        local rc=$?
        if [ $rc -eq 124 ]; then
            echo "⏰ Module $description timed out (${MODULE_TIMEOUT}s no output), skipping"
        else
            echo "❌ Module $description failed (exit $rc), skipping"
        fi
        return $rc
    fi
}

# Export variables for modules
export CONTAINER PROJECT IMAGE GH_ORG_VAR GH_PROJECT_VAR GITHUB_TOKEN FRAMEWORKS FIGMA_PROJECT REPO_NAME REPO_CMD

# Run modules in sequence with fault tolerance
echo "🔧 Phase 1: Cleanup & Preparation"
run_module "01-ssh-cleanup.sh" "SSH Cleanup" "$CONTAINER" || echo "⚠️  SSH cleanup failed, continuing..."
run_module "02-tailscale-cleanup.sh" "Tailscale Cleanup" "$CONTAINER" || echo "⚠️  Tailscale cleanup failed, continuing..."

echo
echo "🏗️  Phase 2: Infrastructure"
if ! run_module "03-lxc-container.sh" "LXC Container Setup" "$CONTAINER" "$PROJECT" "$IMAGE"; then
    echo "💥 CRITICAL: Container setup failed, cannot continue"
    exit 1
fi

echo
echo "🔗 Phase 3: Network & Services"
# Add more modules here as you create them:
# run_module "04-tailscale-connect.sh" "Tailscale Connection" "$CONTAINER" || echo "⚠️  Tailscale connection failed"
# run_module "05-base-tools.sh" "Base Tools Installation" "$CONTAINER" || echo "⚠️  Base tools installation failed"
# run_module "06-repo-clone.sh" "Repository Clone" "$CONTAINER" "$REPO_CMD" "$REPO_NAME" || echo "⚠️  Repository clone failed"
# run_module "07-framework-setup.sh" "Framework Setup" "$CONTAINER" "$REPO_NAME" "$FRAMEWORKS" || echo "⚠️  Framework setup failed"

echo
echo "🎯 Workflow Status Summary:"
echo "✅ SSH cleanup: attempted"
echo "✅ Tailscale cleanup: attempted" 
echo "✅ LXC container: ready"
echo "🔄 Additional modules: TODO"

echo
echo "📋 Manual Steps (temporary until modules complete):"
echo "1. Connect to container:"
echo "   lxc exec $CONTAINER -- bash"
echo "2. Install base tools and clone repo:"
echo "   apt-get update && apt-get install -y git curl"
echo "   cd /home/ubuntu && git clone https://\${GITHUB_TOKEN}@github.com/$GH_ORG_VAR/$GH_PROJECT_VAR.git"
echo
echo "🚀 Container is ready for development!"
