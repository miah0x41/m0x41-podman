#!/bin/bash
# upgrade-snap.sh — Stop rootless podman services, reinstall snap, restart, verify health.
# Usage: ./scripts/upgrade-snap.sh <path-to-snap-file>
#
# Run as your normal user (not sudo). The script uses sudo internally
# only for snap install/remove and system-level daemon-reload.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Do not run this script as root. Run as your normal user:"
    echo "  $0 $*"
    exit 1
fi

SNAP_FILE="${1:-}"
if [ -z "${SNAP_FILE}" ] || [ ! -f "${SNAP_FILE}" ]; then
    echo "Usage: $0 <path-to-snap-file>"
    echo "  e.g. $0 m0x41-podman_5.8.1+20260407.g03c0a7f_amd64.snap"
    exit 1
fi

# Resolve to absolute path before we start.
SNAP_FILE="$(readlink -f "${SNAP_FILE}")"

# Verify sudo access (will prompt if needed).
if ! sudo -v; then
    echo "This script requires sudo access for snap install/remove."
    exit 1
fi

PODMAN="/usr/local/bin/podman"
if [ ! -x "${PODMAN}" ]; then
    PODMAN="snap run m0x41-podman"
fi

# ---------- 1. Discover rootless state ----------
echo "=== Step 1: Discover rootless services and containers ==="

# Quadlet-generated and podman-related user services (active ones).
SAVED_SERVICES=()
while IFS= read -r unit; do
    [ -n "${unit}" ] && SAVED_SERVICES+=("${unit}")
done < <(systemctl --user list-units --type=service --state=active --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E "podman|quadlet|container" || true)

# Also capture enabled timers (auto-update, healthcheck).
SAVED_TIMERS=()
while IFS= read -r unit; do
    [ -n "${unit}" ] && SAVED_TIMERS+=("${unit}")
done < <(systemctl --user list-units --type=timer --state=active --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E "podman" || true)

# Running containers with names and health config.
SAVED_CONTAINERS=()
while IFS= read -r line; do
    [ -n "${line}" ] && SAVED_CONTAINERS+=("${line}")
done < <(${PODMAN} ps --format '{{.Names}}' 2>/dev/null || true)

echo "  Active user services: ${SAVED_SERVICES[*]:-none}"
echo "  Active user timers:   ${SAVED_TIMERS[*]:-none}"
echo "  Running containers:   ${SAVED_CONTAINERS[*]:-none}"

# ---------- 2. Stop rootless services and containers ----------
echo ""
echo "=== Step 2: Stop rootless services and containers ==="

# Stop user timers first (prevents restarts during shutdown).
for timer in "${SAVED_TIMERS[@]}"; do
    echo "  Stopping timer: ${timer}"
    systemctl --user stop "${timer}" 2>/dev/null || true
done

# Stop user services.
for svc in "${SAVED_SERVICES[@]}"; do
    echo "  Stopping service: ${svc}"
    systemctl --user stop "${svc}" 2>/dev/null || true
done

# Stop any remaining running containers.
if [ ${#SAVED_CONTAINERS[@]} -gt 0 ]; then
    echo "  Stopping all rootless containers..."
    ${PODMAN} stop --all --timeout 15 2>/dev/null || true
fi

echo "  Done."

# ---------- 3. Remove and reinstall snap ----------
echo ""
echo "=== Step 3: Remove old snap and install new one ==="

echo "  Removing m0x41-podman..."
sudo snap remove --purge m0x41-podman

echo "  Installing ${SNAP_FILE}..."
sudo snap install "${SNAP_FILE}" --dangerous --classic

# The install hook runs automatically — it recreates the shim,
# generators, systemd units, and man page symlinks.
PODMAN="/usr/local/bin/podman"

echo "  Reloading systemd..."
sudo systemctl daemon-reload
systemctl --user daemon-reload

echo "  Installed: $(${PODMAN} --version 2>/dev/null || echo 'unknown')"

# ---------- 4. Restart rootless services ----------
echo ""
echo "=== Step 4: Restart rootless services ==="

# Restart user services.
for svc in "${SAVED_SERVICES[@]}"; do
    echo "  Starting service: ${svc}"
    if systemctl --user start "${svc}" 2>&1; then
        echo "    OK"
    else
        echo "    FAILED — check: systemctl --user status ${svc}"
    fi
done

# Restart user timers.
for timer in "${SAVED_TIMERS[@]}"; do
    echo "  Starting timer: ${timer}"
    if systemctl --user start "${timer}" 2>&1; then
        echo "    OK"
    else
        echo "    FAILED — check: systemctl --user status ${timer}"
    fi
done

if [ ${#SAVED_SERVICES[@]} -eq 0 ] && [ ${#SAVED_TIMERS[@]} -eq 0 ]; then
    echo "  No services or timers to restart."
fi

# ---------- 5. Health checks ----------
echo ""
echo "=== Step 5: Health checks ==="

FAILURES=0

# 5a: Snap binary works.
echo "--- snap binary ---"
if ${PODMAN} --version >/dev/null 2>&1; then
    echo "  PASS: podman binary responds"
else
    echo "  FAIL: podman binary not responding"
    FAILURES=$((FAILURES + 1))
fi

# 5b: Shim exists and is ours.
echo "--- shim ---"
if [ -x /usr/local/bin/podman ] && grep -q "m0x41-podman shim" /usr/local/bin/podman 2>/dev/null; then
    echo "  PASS: shim exists at /usr/local/bin/podman"
else
    echo "  FAIL: shim missing or not ours"
    FAILURES=$((FAILURES + 1))
fi

# 5c: Quadlet symlink.
echo "--- quadlet ---"
if [ -L /usr/libexec/podman/quadlet ] && \
   readlink /usr/libexec/podman/quadlet 2>/dev/null | grep -q m0x41-podman; then
    echo "  PASS: quadlet symlink exists"
else
    echo "  FAIL: quadlet symlink missing"
    FAILURES=$((FAILURES + 1))
fi

# 5d: Systemd generators.
echo "--- generators ---"
for gen in /usr/lib/systemd/system-generators/podman-system-generator \
           /usr/lib/systemd/user-generators/podman-user-generator; do
    if [ -L "${gen}" ] && readlink "${gen}" 2>/dev/null | grep -q m0x41-podman; then
        echo "  PASS: $(basename ${gen})"
    else
        echo "  FAIL: $(basename ${gen}) missing"
        FAILURES=$((FAILURES + 1))
    fi
done

# 5e: Restarted services are active.
echo "--- restarted services ---"
for svc in "${SAVED_SERVICES[@]}"; do
    if systemctl --user is-active "${svc}" >/dev/null 2>&1; then
        echo "  PASS: ${svc} is active"
    else
        echo "  FAIL: ${svc} is not active"
        FAILURES=$((FAILURES + 1))
    fi
done

# 5f: Healthcheck validation — test with a throwaway container.
echo "--- healthcheck ---"
HC_NAME="upgrade-hc-test-$$"
if ${PODMAN} run -d --name "${HC_NAME}" \
    --health-cmd "echo ok" \
    --health-interval 5s \
    --health-start-period 0s \
    docker.io/library/alpine:latest sleep 120 >/dev/null 2>&1; then

    # Wait for first healthcheck to run.
    HC_HEALTHY=false
    for i in $(seq 1 12); do
        HC_STATUS=$(${PODMAN} inspect --format '{{.State.Health.Status}}' "${HC_NAME}" 2>/dev/null) || true
        if [ "${HC_STATUS}" = "healthy" ]; then
            HC_HEALTHY=true
            break
        fi
        sleep 5
    done

    if ${HC_HEALTHY}; then
        echo "  PASS: healthcheck container reached healthy status"
    else
        echo "  FAIL: healthcheck container status is '${HC_STATUS}' after 60s"
        FAILURES=$((FAILURES + 1))
    fi

    ${PODMAN} rm -f "${HC_NAME}" >/dev/null 2>&1 || true
else
    echo "  FAIL: could not start healthcheck test container"
    FAILURES=$((FAILURES + 1))
fi

# ---------- Summary ----------
echo ""
echo "========================================"
if [ ${FAILURES} -eq 0 ]; then
    echo "  Upgrade complete — all checks passed"
else
    echo "  Upgrade complete — ${FAILURES} check(s) failed"
fi
echo "========================================"
exit ${FAILURES}
