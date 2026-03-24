#!/bin/bash
# 01_launch.sh — Creates LXD container, pushes snap project, triggers build
# Run from the host within `newgrp lxd`.
set -euo pipefail

CONTAINER_NAME="m0x41-podman-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 1: Create LXD container ==="
if lxc info "${CONTAINER_NAME}" &>/dev/null; then
    echo "Container '${CONTAINER_NAME}' already exists."
    STATE=$(lxc info "${CONTAINER_NAME}" | grep "^Status:" | awk '{print $2}')
    if [ "${STATE}" != "RUNNING" ]; then
        echo "Starting existing container..."
        lxc start "${CONTAINER_NAME}"
    fi
else
    echo "Launching Ubuntu 22.04 container..."
    lxc launch ubuntu:22.04 "${CONTAINER_NAME}" \
        -c security.nesting=true

    echo "Waiting for container networking..."
    for i in $(seq 1 30); do
        if lxc exec "${CONTAINER_NAME}" -- ping -c1 -W1 archive.ubuntu.com &>/dev/null; then
            break
        fi
        sleep 1
    done
fi

echo "Container IP: $(lxc list "${CONTAINER_NAME}" -f csv -c 4 | cut -d' ' -f1)"

echo "=== Step 2: Push snap project files ==="
lxc exec "${CONTAINER_NAME}" -- mkdir -p /root/snap-build/snap /root/snap-build/scripts

lxc file push "${PROJECT_DIR}/snapcraft.yaml" "${CONTAINER_NAME}/root/snap-build/snapcraft.yaml"
for f in containers.conf storage.conf registries.conf policy.json; do
    lxc file push "${PROJECT_DIR}/snap/${f}" "${CONTAINER_NAME}/root/snap-build/snap/${f}"
done
lxc file push "${PROJECT_DIR}/scripts/podman-wrapper" "${CONTAINER_NAME}/root/snap-build/scripts/podman-wrapper"
lxc exec "${CONTAINER_NAME}" -- chmod +x /root/snap-build/scripts/podman-wrapper

lxc exec "${CONTAINER_NAME}" -- mkdir -p /root/snap-build/snap/hooks
for f in install remove; do
    lxc file push "${PROJECT_DIR}/snap/hooks/${f}" "${CONTAINER_NAME}/root/snap-build/snap/hooks/${f}"
done
lxc exec "${CONTAINER_NAME}" -- chmod +x /root/snap-build/snap/hooks/install /root/snap-build/snap/hooks/remove

lxc file push "${SCRIPT_DIR}/02_build_snap.sh" "${CONTAINER_NAME}/root/02_build_snap.sh"
lxc exec "${CONTAINER_NAME}" -- chmod +x /root/02_build_snap.sh

echo "=== Step 3: Build snap ==="
lxc exec "${CONTAINER_NAME}" -- /root/02_build_snap.sh

echo "=== Step 4: Pull built snap ==="
SNAP_FILE=$(lxc exec "${CONTAINER_NAME}" -- find /root/snap-build -maxdepth 1 -name "*.snap" -type f | head -1)
if [ -n "${SNAP_FILE}" ]; then
    lxc file pull "${CONTAINER_NAME}${SNAP_FILE}" "${PROJECT_DIR}/"
    BASENAME=$(basename "${SNAP_FILE}")
    echo ""
    echo "============================================"
    echo "  Snap built successfully!"
    echo "  Output: ${PROJECT_DIR}/${BASENAME}"
    echo ""
    echo "  Install:  sudo snap install ${BASENAME} --dangerous --classic"
    echo "  Destroy:  lxc delete --force ${CONTAINER_NAME}"
    echo "============================================"
else
    echo "ERROR: No .snap file found in build directory"
    exit 1
fi
