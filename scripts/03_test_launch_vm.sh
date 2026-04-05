#!/bin/bash
# 03_test_launch_vm.sh — Creates a fresh LXD VM, installs the snap, runs tests
# Run from the host within `newgrp lxd`.
# Usage: ./scripts/03_test_launch_vm.sh [tier1|tier2|tier3|tier4|all]
#
# Differences from 03_test_launch.sh (container mode):
#   - Uses `lxc launch --vm` (full VM, not system container)
#   - No security.nesting or syscalls.intercept flags (full kernel in VM)
#   - Longer startup wait (VM boot is slower)
#   - security.secureboot=false (needed for unsigned kernel)
set -euo pipefail

CONTAINER_NAME="m0x41-podman-test-vm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SNAP_FILE=$(ls -t "${PROJECT_DIR}"/m0x41-podman_*.snap 2>/dev/null | head -1)
TIER="${1:-all}"

if [ -z "${SNAP_FILE}" ] || [ ! -f "${SNAP_FILE}" ]; then
    echo "ERROR: No snap file found in: ${PROJECT_DIR}"
    echo "Build it first with: ./scripts/01_launch.sh"
    exit 1
fi
SNAP_BASENAME=$(basename "${SNAP_FILE}")

echo "=== Step 1: Create LXD VM ==="
if lxc info "${CONTAINER_NAME}" &>/dev/null; then
    echo "VM '${CONTAINER_NAME}' already exists."
    STATE=$(lxc info "${CONTAINER_NAME}" | grep "^Status:" | awk '{print $2}')
    if [ "${STATE}" != "RUNNING" ]; then
        echo "Starting existing VM..."
        lxc start "${CONTAINER_NAME}"
    fi
else
    echo "Launching Ubuntu 24.04 VM..."
    lxc launch ubuntu:24.04 "${CONTAINER_NAME}" --vm \
        -c security.secureboot=false

    echo "Waiting for VM boot and networking (this takes longer than containers)..."
    for i in $(seq 1 90); do
        if lxc exec "${CONTAINER_NAME}" -- ping -c1 -W1 archive.ubuntu.com &>/dev/null; then
            echo "VM networking ready after ${i}s"
            break
        fi
        sleep 1
    done
fi

echo "VM IP: $(lxc list "${CONTAINER_NAME}" -f csv -c 4 | cut -d' ' -f1)"

echo "=== Step 2: Push snap and scripts ==="
lxc file push "${SNAP_FILE}" "${CONTAINER_NAME}/root/m0x41-podman_5.8.1_amd64.snap"  # inner scripts expect this name
lxc file push "${SCRIPT_DIR}/04_test_setup.sh" "${CONTAINER_NAME}/root/04_test_setup.sh"
lxc file push "${SCRIPT_DIR}/05_run_tests.sh" "${CONTAINER_NAME}/root/05_run_tests.sh"
lxc exec "${CONTAINER_NAME}" -- chmod +x /root/04_test_setup.sh /root/05_run_tests.sh

echo "=== Step 3: Install snap and configure ==="
lxc exec "${CONTAINER_NAME}" -- /root/04_test_setup.sh

echo "=== Step 4: Run tests (${TIER}) ==="
lxc exec "${CONTAINER_NAME}" -- /root/05_run_tests.sh "${TIER}"
