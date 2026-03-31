#!/bin/bash
# 10_wrapper_tests.sh — Runs INSIDE the LXD container as root
# Tests the podman-wrapper's first-run hello message, dependency detection,
# marker file logic, and alias tip across all wrapper branches.
# Expects 09_wrapper_test_setup.sh to have run first (minimal setup, no deps).
set -euo pipefail

TESTUSER="podtest"
MARKER_DIR="/home/${TESTUSER}/.local/share/m0x41-podman"
HELLO_MARKER="${MARKER_DIR}/.hello"
DEPS_MARKER="${MARKER_DIR}/.deps-ok"
SNAP_REV=$(basename "$(readlink -f /snap/m0x41-podman/current)")

# Invoke the wrapper directly with snap env vars set, rather than via
# `snap run`. On Ubuntu, `snap run` may swallow the wrapper's stderr.
# This tests the wrapper logic itself, which is the purpose of this suite.
SNAP="/snap/m0x41-podman/current"
PODMAN_ENV="SNAP=${SNAP} SNAP_VERSION=5.8.1 SNAP_REVISION=${SNAP_REV}"
PODMAN_CMD="${SNAP}/bin/podman-wrapper"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

run_as_testuser() {
    local cmd="$1" output_file="${2:-}"
    local uid
    uid=$(id -u "${TESTUSER}")
    mkdir -p "/run/user/${uid}"
    chown "${TESTUSER}:${TESTUSER}" "/run/user/${uid}"
    if [ -n "${output_file}" ]; then
        su - "${TESTUSER}" -c "
            export XDG_RUNTIME_DIR=/run/user/${uid} ${PODMAN_ENV}
            ${cmd}
        " >"${output_file}" 2>&1
    else
        su - "${TESTUSER}" -c "
            export XDG_RUNTIME_DIR=/run/user/${uid} ${PODMAN_ENV}
            ${cmd}
        "
    fi
}

# Detect distro for assertions
. /etc/os-release
case "${ID}" in
    ubuntu|debian)       EXPECTED_PKG_CMD="sudo apt install" ;;
    fedora|centos|rocky|almalinux|rhel) EXPECTED_PKG_CMD="sudo dnf install" ;;
    *)                   EXPECTED_PKG_CMD="" ;;
esac

echo "=========================================="
echo "  Podman Wrapper Dependency Tests"
echo "  Distro: ${ID} ${VERSION_ID:-rolling}"
echo "  Snap revision: ${SNAP_REV}"
echo "  Date: $(date -Iseconds)"
echo "=========================================="

# ============================================================
# Phase 1: Root — No Hello, No Warnings
# ============================================================
echo ""
echo "===== PHASE 1: Root Invocation ====="

echo "--- root: no hello message ---"
ROOT_OUT=$(${PODMAN_ENV} ${PODMAN_CMD} --version 2>&1) || true
if echo "${ROOT_OUT}" | grep -q "Welcome to m0x41-podman"; then
    fail "root: hello message shown (should be suppressed)"
else
    pass "root: no hello message"
fi

echo "--- root: no dependency warning ---"
ROOT_OUT2=$(${PODMAN_ENV} ${PODMAN_CMD} --version 2>&1) || true
if echo "${ROOT_OUT2}" | grep -q "WARNING: missing host dependencies"; then
    fail "root: dependency warning shown (should be suppressed)"
else
    pass "root: no dependency warning"
fi

# ============================================================
# Phase 2: First Rootless Run — Hello + Alias Tip + Dep Warning
# ============================================================
echo ""
echo "===== PHASE 2: First Rootless Invocation ====="

# Ensure clean state
rm -rf "${MARKER_DIR}"

# Temporarily move the install hook's shim out of the way so we can test
# the "not aliased" path (alias tip should be shown when no shim exists).
SHIM_MOVED=false
if [ -f /usr/local/bin/podman ] && grep -q "m0x41-podman shim" /usr/local/bin/podman 2>/dev/null; then
    mv /usr/local/bin/podman /usr/local/bin/podman.bak
    SHIM_MOVED=true
fi

echo "--- first run: capturing stderr ---"
STDERR_P2="/tmp/wrapper-phase2-stderr"
run_as_testuser "${PODMAN_CMD} --version" "${STDERR_P2}" || true

echo "--- first run: hello message shown ---"
if grep -q "Welcome to m0x41-podman" "${STDERR_P2}" 2>/dev/null; then
    pass "first run: hello message shown"
else
    fail "first run: hello message not shown"
fi

echo "--- first run: alias tip shown ---"
if grep -q "sudo snap alias m0x41-podman podman" "${STDERR_P2}" 2>/dev/null; then
    pass "first run: alias tip shown"
else
    fail "first run: alias tip not shown"
fi

echo "--- first run: hello marker created ---"
if [ -f "${HELLO_MARKER}" ]; then
    pass "first run: hello marker created"
else
    fail "first run: hello marker not created"
fi

echo "--- first run: dependency warning shown ---"
if grep -q "WARNING: missing host dependencies" "${STDERR_P2}" 2>/dev/null; then
    pass "first run: dependency warning shown"
else
    fail "first run: dependency warning not shown"
fi

echo "--- first run: distro-specific install command ---"
if [ -n "${EXPECTED_PKG_CMD}" ]; then
    if grep -q "${EXPECTED_PKG_CMD}" "${STDERR_P2}" 2>/dev/null; then
        pass "first run: distro-specific install command (${EXPECTED_PKG_CMD})"
    else
        fail "first run: expected '${EXPECTED_PKG_CMD}' not in stderr"
    fi
else
    pass "first run: distro-specific install command (skipped — unknown distro)"
fi

echo "--- first run: suppress instructions shown ---"
if grep -q "To suppress this warning" "${STDERR_P2}" 2>/dev/null; then
    pass "first run: suppress instructions shown"
else
    fail "first run: suppress instructions not shown"
fi

# Restore the shim if we moved it
if [ "${SHIM_MOVED}" = true ]; then
    mv /usr/local/bin/podman.bak /usr/local/bin/podman
fi

# ============================================================
# Phase 3: Second Rootless Run — No Hello, Still Warns
# ============================================================
echo ""
echo "===== PHASE 3: Second Rootless Invocation ====="

STDERR_P3="/tmp/wrapper-phase3-stderr"
run_as_testuser "${PODMAN_CMD} --version" "${STDERR_P3}" || true

echo "--- second run: no hello message ---"
if grep -q "Welcome to m0x41-podman" "${STDERR_P3}" 2>/dev/null; then
    fail "second run: hello message repeated"
else
    pass "second run: no hello message"
fi

echo "--- second run: dependency warning persists ---"
if grep -q "WARNING: missing host dependencies" "${STDERR_P3}" 2>/dev/null; then
    pass "second run: dependency warning persists"
else
    fail "second run: dependency warning missing"
fi

echo "--- second run: suppress instructions shown ---"
if grep -q "To suppress this warning" "${STDERR_P3}" 2>/dev/null; then
    pass "second run: suppress instructions shown"
else
    fail "second run: suppress instructions not shown"
fi

# ============================================================
# Phase 4: Manual Suppression via Marker File
# ============================================================
echo ""
echo "===== PHASE 4: Manual Suppression ====="

# Create the marker as the test user (mimics user following the suppress instructions)
run_as_testuser "mkdir -p ${MARKER_DIR} && echo ${SNAP_REV} > ${DEPS_MARKER}" || true

STDERR_P4="/tmp/wrapper-phase4-stderr"
run_as_testuser "${PODMAN_CMD} --version" "${STDERR_P4}" || true

echo "--- suppressed: no dependency warning ---"
if grep -q "WARNING: missing host dependencies" "${STDERR_P4}" 2>/dev/null; then
    fail "suppressed: dependency warning still shown"
else
    pass "suppressed: no dependency warning"
fi

echo "--- suppressed: no hello message ---"
if grep -q "Welcome to m0x41-podman" "${STDERR_P4}" 2>/dev/null; then
    fail "suppressed: hello message shown"
else
    pass "suppressed: no hello message"
fi

# Remove marker to reset state for next phase
run_as_testuser "rm -f ${DEPS_MARKER}" || true

# ============================================================
# Phase 5: Install Dependencies — Silent Marker Creation
# ============================================================
echo ""
echo "===== PHASE 5: After Installing Dependencies ====="

echo "--- installing missing dependencies ---"
/root/install_deps.sh

STDERR_P5="/tmp/wrapper-phase5-stderr"
run_as_testuser "${PODMAN_CMD} --version" "${STDERR_P5}" || true

echo "--- deps installed: newuidmap/newgidmap no longer missing ---"
if grep -q "newuidmap\|newgidmap" "${STDERR_P5}" 2>/dev/null; then
    fail "deps installed: newuidmap/newgidmap still reported missing"
else
    pass "deps installed: newuidmap/newgidmap no longer missing"
fi

# Note: dbus-user-session may still appear "missing" in LXD containers because
# su - does not create a logind session, so dbus-send --session always fails.
# This is a container environment limitation, not a wrapper bug.
# We only check that the binary deps (uidmap) were resolved.
# libgpg-error is no longer checked by the wrapper — handled by conmon/crun wrappers.

echo "--- deps installed: marker behaviour ---"
# If all deps are satisfied (no WARNING at all), the marker should be created.
# If dbus-user-session is still flagged (container limitation), marker won't exist
# and that's acceptable. Test both paths.
if grep -q "WARNING: missing host dependencies" "${STDERR_P5}" 2>/dev/null; then
    # Warning still present (expected in containers due to dbus) — marker should NOT exist
    if [ ! -f "${DEPS_MARKER}" ]; then
        pass "deps installed: marker correctly absent (dbus-user-session still flagged in container)"
    else
        fail "deps installed: marker created despite active warning"
    fi
else
    # No warning — marker should exist with correct revision
    if [ -f "${DEPS_MARKER}" ]; then
        MARKER_CONTENT=$(cat "${DEPS_MARKER}" 2>/dev/null)
        if [ "${MARKER_CONTENT}" = "${SNAP_REV}" ]; then
            pass "deps installed: deps-ok marker created (rev ${SNAP_REV})"
        else
            fail "deps installed: marker content '${MARKER_CONTENT}' != '${SNAP_REV}'"
        fi
    else
        fail "deps installed: deps-ok marker not created"
    fi
fi

# ============================================================
# Phase 6: Alias Tip Suppression
# ============================================================
echo ""
echo "===== PHASE 6: Alias Tip When Aliased ====="

# Reset hello marker to re-trigger first-run message
rm -f "${HELLO_MARKER}"

# Create alias symlink
ln -sf m0x41-podman /snap/bin/podman 2>/dev/null || true

STDERR_P6="/tmp/wrapper-phase6-stderr"
run_as_testuser "${PODMAN_CMD} --version" "${STDERR_P6}" || true

echo "--- aliased: hello shown ---"
if grep -q "Welcome to m0x41-podman" "${STDERR_P6}" 2>/dev/null; then
    pass "aliased: hello message shown"
else
    fail "aliased: hello message not shown"
fi

echo "--- aliased: no alias tip ---"
if grep -q "sudo snap alias" "${STDERR_P6}" 2>/dev/null; then
    fail "aliased: alias tip shown (should be suppressed)"
else
    pass "aliased: no alias tip"
fi

echo "--- aliased: hello marker re-created ---"
if [ -f "${HELLO_MARKER}" ]; then
    pass "aliased: hello marker re-created"
else
    fail "aliased: hello marker not re-created"
fi

# Teardown
rm -f /snap/bin/podman 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
echo ""
echo "=========================================="
if [ "${FAILURES}" -eq 0 ]; then
    echo "  All tests passed!"
else
    echo "  ${FAILURES} test(s) FAILED"
fi
echo "=========================================="
exit "${FAILURES}"
