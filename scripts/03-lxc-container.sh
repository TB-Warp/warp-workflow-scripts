#!/bin/bash
# LXC Container Management Module - Create and start ephemeral container
set -euo pipefail

CONTAINER="${1:-${CONTAINER:-}}"
PROJECT="${2:-${PROJECT:-}}"
IMAGE="${3:-${IMAGE:-ubuntu:24.04}}"

if [ -z "$CONTAINER" ]; then
    echo "ERROR: CONTAINER name required"
    exit 1
fi

STORAGE_POOL="SSD1TB"
PROFILE="shared-client"

# Handle IMAGE environment variable with flexible naming
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
        IMAGE_FALLBACK="images:ubuntu/24.04"
        ;;
esac

echo "==> LXC Container: Setting up ${CONTAINER} with image ${IMAGE_PRIMARY}..."

# Switch to project if specified
if [ -n "${PROJECT:-}" ]; then
    echo "Switching to LXD project: ${PROJECT}"
    if ! lxc project switch "${PROJECT}" 2>/dev/null; then
        if ! lxc project list | grep -q "${PROJECT}"; then
            echo "ERROR: Project '${PROJECT}' does not exist"
            lxc project list
            exit 1
        fi
    fi
    echo "✅ Successfully switched to project '${PROJECT}'"
else
    CURRENT_PROJECT=$(lxc project list --format csv | grep "^.*,YES" | cut -d, -f1 || echo "default")
    PROJECT="${CURRENT_PROJECT}"
    echo "Using default LXD project: ${PROJECT}"
fi

# Clean slate: Remove ALL containers in project
echo "Complete clean-slate: Removing ALL containers in project '${PROJECT}'..."
EXISTING_CONTAINERS=$(lxc list --format csv -c n 2>/dev/null || true)
if [ -n "${EXISTING_CONTAINERS:-}" ]; then
    echo "Found existing containers, cleaning up for clean-slate..."
    while IFS= read -r container_name; do
        if [ -n "$container_name" ]; then
            echo "Deleting container: $container_name"
            lxc delete "$container_name" --force >/dev/null 2>&1 || true
        fi
    done <<< "$EXISTING_CONTAINERS"
    echo "✅ All containers deleted from project '${PROJECT}'"
else
    echo "No existing containers found in project '${PROJECT}'"
fi

# Launch new ephemeral container
echo "Launching ephemeral container with image '${IMAGE_PRIMARY}'..."
set +e
lxc launch "${IMAGE_PRIMARY}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}"
LAUNCH_RC=$?
set -e

if [ "${LAUNCH_RC}" -ne 0 ]; then
    echo "Primary image failed, falling back to '${IMAGE_FALLBACK}'..."
    set +e
    lxc launch "${IMAGE_FALLBACK}" "${CONTAINER}" --ephemeral --storage "${STORAGE_POOL}" --profile "${PROFILE}"
    FALLBACK_RC=$?
    set -e
    if [ "${FALLBACK_RC}" -ne 0 ]; then
        echo "Both container launches failed! Trying basic launch without storage pool..."
        lxc launch "${IMAGE_FALLBACK}" "${CONTAINER}" --ephemeral --profile "${PROFILE}" || {
            echo "ERROR: Failed to launch container after all attempts"
            exit 1
        }
    fi
fi

# Wait for container to be RUNNING
echo "Waiting for container to be RUNNING..."
for i in $(seq 1 60); do
    STATE="$(lxc list -c ns --format csv | awk -F, -v n="${CONTAINER}" '$1==n{print $2}')"
    if [ "${STATE:-}" = "RUNNING" ]; then
        echo "✅ Container is RUNNING"
        break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
        echo "ERROR: Container did not reach RUNNING state in time"
        exit 1
    fi
done

# Basic access test
echo "Testing basic LXC access..."
lxc exec "${CONTAINER}" -- bash -lc 'echo "✅ Container access OK: $(uname -a)"'

echo "✅ LXC Container setup complete"
exit 0
