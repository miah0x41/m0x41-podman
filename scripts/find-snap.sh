#!/bin/bash
# find-snap.sh — Locate the snap file matching the current HEAD.
# Sourced by host-side test scripts. Sets SNAP_FILE or exits with an error.
# Expects PROJECT_DIR to be set by the caller.

GIT_SHORT=$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SNAP_FILE=$(ls -t "${PROJECT_DIR}"/m0x41-podman_*".g${GIT_SHORT}_"*.snap 2>/dev/null | head -1 || true)

if [ -z "${SNAP_FILE}" ] || [ ! -f "${SNAP_FILE}" ]; then
    echo "ERROR: No snap matching HEAD (${GIT_SHORT}) in: ${PROJECT_DIR}"
    echo "Build it first with: ./scripts/01_launch.sh"
    exit 1
fi
echo "Using snap: $(basename "${SNAP_FILE}")"
