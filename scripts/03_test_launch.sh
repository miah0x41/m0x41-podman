#!/bin/bash
# 03_test_launch.sh — Creates a fresh LXD container, installs the snap, runs tests
# Run from the host within `newgrp lxd`.
# Usage: ./scripts/03_test_launch.sh [tier1|tier2|tier3|tier4|all]
set -euo pipefail

CONTAINER_NAME="podman-m0x41-test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SNAP_FILE="${PROJECT_DIR}/podman-m0x41_5.8.1_amd64.snap"
TIER="${1:-all}"

if [ ! -f "${SNAP_FILE}" ]; then
    echo "ERROR: Snap file not found: ${SNAP_FILE}"
    echo "Build it first with: ./scripts/01_launch.sh"
    exit 1
fi

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
        -c security.nesting=true \
        -c security.syscalls.intercept.mknod=true \
        -c security.syscalls.intercept.setxattr=true

    echo "Waiting for container networking..."
    for i in $(seq 1 30); do
        if lxc exec "${CONTAINER_NAME}" -- ping -c1 -W1 archive.ubuntu.com &>/dev/null; then
            break
        fi
        sleep 1
    done
fi

echo "Container IP: $(lxc list "${CONTAINER_NAME}" -f csv -c 4 | cut -d' ' -f1)"

echo "=== Step 2: Push snap and scripts ==="
lxc file push "${SNAP_FILE}" "${CONTAINER_NAME}/root/podman-m0x41_5.8.1_amd64.snap"
lxc file push "${SCRIPT_DIR}/04_test_setup.sh" "${CONTAINER_NAME}/root/04_test_setup.sh"
lxc file push "${SCRIPT_DIR}/05_run_tests.sh" "${CONTAINER_NAME}/root/05_run_tests.sh"
lxc exec "${CONTAINER_NAME}" -- chmod +x /root/04_test_setup.sh /root/05_run_tests.sh

echo "=== Step 3: Install snap and configure ==="
lxc exec "${CONTAINER_NAME}" -- /root/04_test_setup.sh

echo "=== Step 4: Run tests (${TIER}) ==="
lxc exec "${CONTAINER_NAME}" -- /root/05_run_tests.sh "${TIER}"
