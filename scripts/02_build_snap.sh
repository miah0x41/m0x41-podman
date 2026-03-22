#!/bin/bash
# 02_build_snap.sh — Runs INSIDE the LXD container as root
# Installs snapcraft 7.x (for core22) and builds the snap in destructive mode
set -euo pipefail

BUILD_DIR="/root/snap-build"

echo "=== Phase 1: Install snapcraft ==="
snap wait system seed.loaded 2>/dev/null || true

if ! command -v snapcraft &>/dev/null; then
    echo "Installing snapcraft (7.x for core22)..."
    snap install snapcraft --classic --channel=7.x/stable
fi
echo "snapcraft version: $(snapcraft --version)"

echo "=== Phase 2: Build snap (destructive mode) ==="
cd "${BUILD_DIR}"
snapcraft --destructive-mode --verbosity=verbose

echo ""
echo "=== Build complete ==="
ls -lh "${BUILD_DIR}"/*.snap
