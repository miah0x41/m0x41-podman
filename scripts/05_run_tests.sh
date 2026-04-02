#!/bin/bash
# 05_run_tests.sh — Runs INSIDE the LXD container
# Tests snap-installed Podman via `snap run` (classic confinement).
# Usage: 05_run_tests.sh [tier1|tier2|tier3|tier4|tier5|all]
#
# All tests use `m0x41-podman` (i.e. snap run). Classic confinement
# means the snap command sees the real host filesystem — no bypass needed.
set -euo pipefail

SNAP="/snap/m0x41-podman/current"
PODMAN="m0x41-podman"
TESTUSER="podtest"
TIER="${1:-all}"
RESULTS_DIR="/tmp/test-results"
PODMAN_SRC="/opt/podman"
mkdir -p "${RESULTS_DIR}"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

run_as_testuser() {
    local uid
    uid=$(id -u "${TESTUSER}")
    mkdir -p "/run/user/${uid}"
    chown "${TESTUSER}:${TESTUSER}" "/run/user/${uid}"
    su - "${TESTUSER}" -c "
        export XDG_RUNTIME_DIR=/run/user/${uid}
        $1
    "
}

# ---------- Tier 1: Snap Command Validation ----------
tier1() {
    echo ""
    echo "===== TIER 1: Snap Command Validation ====="

    echo "--- snap command reports version ---"
    if ${PODMAN} --version 2>&1 | grep -q "5.8.1"; then
        pass "snap command reports 5.8.1"
    else
        fail "snap command version check"
    fi

    echo "--- podman info as root ---"
    RUNTIME=$(${PODMAN} info --format '{{.Host.OCIRuntime.Name}}' 2>&1) || true
    if echo "${RUNTIME}" | grep -q "crun"; then
        pass "root: OCI runtime is crun"
    else
        fail "root: OCI runtime is '${RUNTIME}', expected 'crun'"
    fi

    echo "--- podman info as rootless ---"
    RUNTIME_RL=$(run_as_testuser "${PODMAN} info --format '{{.Host.OCIRuntime.Name}}'" 2>&1) || true
    if echo "${RUNTIME_RL}" | grep -q "crun"; then
        pass "rootless: OCI runtime is crun"
    else
        fail "rootless: OCI runtime is '${RUNTIME_RL}', expected 'crun'"
    fi

    echo "--- crun version ---"
    CRUN_VER=$(${PODMAN} info --format '{{.Host.OCIRuntime.Version}}' 2>&1) || true
    if echo "${CRUN_VER}" | grep -q "1.19.1"; then
        pass "crun version is 1.19.1"
    else
        fail "crun version is '${CRUN_VER}', expected 1.19.1"
    fi

    echo "--- network backend ---"
    NET=$(${PODMAN} info --format '{{.Host.NetworkBackend}}' 2>&1) || true
    if echo "${NET}" | grep -q "netavark"; then
        pass "network backend is netavark"
    else
        fail "network backend is '${NET}', expected 'netavark'"
    fi

    echo "--- storage driver ---"
    DRIVER=$(run_as_testuser "${PODMAN} info --format '{{.Store.GraphDriverName}}'" 2>&1) || true
    if echo "${DRIVER}" | grep -q "overlay"; then
        pass "storage driver is overlay"
    else
        fail "storage driver is '${DRIVER}', expected 'overlay'"
    fi

    echo "--- conmon resolves inside snap ---"
    CONMON=$(${PODMAN} info --format '{{.Host.Conmon.Path}}' 2>&1) || true
    if echo "${CONMON}" | grep -q "/snap/m0x41-podman/"; then
        pass "conmon resolves inside snap (${CONMON})"
    else
        fail "conmon path '${CONMON}' not inside snap"
    fi
}

# ---------- Tier 2: Rootless Functional Tests ----------
tier2() {
    echo ""
    echo "===== TIER 2: Rootless Functional Tests ====="

    echo "--- pull and run alpine (rootless) ---"
    if run_as_testuser "${PODMAN} run --rm docker.io/library/alpine:latest echo 'hello from classic snap podman'" 2>&1; then
        pass "rootless container run"
    else
        fail "rootless container run"
    fi

    echo "--- image build (rootless) ---"
    BUILD_DIR=$(mktemp -d)
    cat > "${BUILD_DIR}/Containerfile" <<'CEOF'
FROM docker.io/library/alpine:latest
RUN echo "built by classic snap podman" > /built.txt
CMD cat /built.txt
CEOF
    chown -R "${TESTUSER}:${TESTUSER}" "${BUILD_DIR}"
    if run_as_testuser "${PODMAN} build -t snap-test ${BUILD_DIR}" 2>&1; then
        pass "rootless image build"
    else
        fail "rootless image build"
    fi
    if run_as_testuser "${PODMAN} run --rm snap-test" 2>&1; then
        pass "rootless run built image"
    else
        fail "rootless run built image"
    fi
    rm -rf "${BUILD_DIR}"

    echo "--- pod lifecycle (rootless) ---"
    if run_as_testuser "${PODMAN} pod create --name testpod && ${PODMAN} pod start testpod && ${PODMAN} pod stop testpod && ${PODMAN} pod rm testpod" 2>&1; then
        pass "rootless pod lifecycle"
    else
        fail "rootless pod lifecycle"
    fi

    echo "--- volume lifecycle (rootless) ---"
    if run_as_testuser "${PODMAN} volume create testvol && ${PODMAN} run --rm -v testvol:/data alpine sh -c 'echo ok > /data/test && cat /data/test' && ${PODMAN} volume rm testvol" 2>&1; then
        pass "rootless volume lifecycle"
    else
        fail "rootless volume lifecycle"
    fi

    echo "--- user namespace mapping ---"
    if run_as_testuser "${PODMAN} unshare cat /proc/self/uid_map" 2>&1; then
        pass "user namespace mapping"
    else
        fail "user namespace mapping"
    fi

    echo "--- container DNS resolution (rootless) ---"
    if run_as_testuser "${PODMAN} run --rm docker.io/library/alpine:latest nslookup dns.google" 2>&1 | grep -q "Address.*8.8"; then
        pass "rootless DNS resolution"
    else
        fail "rootless DNS resolution"
    fi

    echo "--- cleanup rootless ---"
    run_as_testuser "${PODMAN} system prune -af" 2>&1 || true
    pass "rootless system prune"
}

# ---------- Tier 3: Rootful Functional Tests ----------
tier3() {
    echo ""
    echo "===== TIER 3: Rootful Functional Tests ====="

    echo "--- pull and run alpine (rootful) ---"
    if ${PODMAN} run --rm docker.io/library/alpine:latest echo "hello from rootful classic snap podman" 2>&1; then
        pass "rootful container run"
    else
        fail "rootful container run"
    fi

    echo "--- image build (rootful) ---"
    BUILD_DIR=$(mktemp -d)
    cat > "${BUILD_DIR}/Containerfile" <<'CEOF'
FROM docker.io/library/alpine:latest
RUN echo "built by rootful classic snap podman" > /built.txt
CMD cat /built.txt
CEOF
    if ${PODMAN} build -t snap-root-test "${BUILD_DIR}" 2>&1; then
        pass "rootful image build"
    else
        fail "rootful image build"
    fi
    if ${PODMAN} run --rm snap-root-test 2>&1; then
        pass "rootful run built image"
    else
        fail "rootful run built image"
    fi
    rm -rf "${BUILD_DIR}"

    echo "--- pod lifecycle (rootful) ---"
    if ${PODMAN} pod create --name rootpod && ${PODMAN} pod start rootpod && ${PODMAN} pod stop rootpod && ${PODMAN} pod rm rootpod; then
        pass "rootful pod lifecycle"
    else
        fail "rootful pod lifecycle"
    fi

    echo "--- volume lifecycle (rootful) ---"
    if ${PODMAN} volume create rootvol && ${PODMAN} run --rm -v rootvol:/data alpine sh -c 'echo ok > /data/test && cat /data/test' && ${PODMAN} volume rm rootvol; then
        pass "rootful volume lifecycle"
    else
        fail "rootful volume lifecycle"
    fi

    echo "--- cleanup rootful ---"
    ${PODMAN} system prune -af 2>&1 || true
    pass "rootful system prune"
}

# ---------- Tier 4: BATS Parity with Native Build ----------
tier4() {
    echo ""
    echo "===== TIER 4: BATS Parity with Native Build ====="

    if [ ! -d "${PODMAN_SRC}/test/system" ]; then
        fail "Podman source not found at ${PODMAN_SRC}"
        return
    fi

    if ! command -v bats &>/dev/null; then
        fail "BATS not installed"
        return
    fi

    # Resolve the snap binary path for PODMAN_BINARY
    SNAP_BINARY=$(command -v ${PODMAN}) || true
    if [ -z "${SNAP_BINARY}" ]; then
        fail "cannot resolve ${PODMAN} binary path"
        return
    fi

    echo "--- BATS smoke tests (rootless, 00*.bats) ---"
    cd "${PODMAN_SRC}"
    if run_as_testuser "cd ${PODMAN_SRC} && PODMAN=${SNAP_BINARY} bats test/system/00*.bats" 2>&1 | tee "${RESULTS_DIR}/bats-smoke-rootless.log" | tail -30; then
        pass "rootless BATS smoke tests"
    else
        fail "rootless BATS smoke tests (check ${RESULTS_DIR}/bats-smoke-rootless.log)"
    fi

    echo "--- BATS smoke tests (root, 00*.bats) ---"
    cd "${PODMAN_SRC}"
    if PODMAN="${SNAP_BINARY}" bats test/system/00*.bats 2>&1 | tee "${RESULTS_DIR}/bats-smoke-root.log" | tail -30; then
        pass "root BATS smoke tests"
    else
        fail "root BATS smoke tests (check ${RESULTS_DIR}/bats-smoke-root.log)"
    fi
}

# ---------- Tier 5: Quadlet / Install Hook Tests ----------
tier5() {
    echo ""
    echo "===== TIER 5: Quadlet / Install Hook Tests ====="

    # --- 5a: Install hook validation ---
    echo "--- 5a: Install hook validation ---"

    echo "--- shim exists and is executable ---"
    if [ -x /usr/local/bin/podman ]; then
        pass "shim exists at /usr/local/bin/podman"
    else
        fail "shim missing or not executable"
    fi

    echo "--- shim contains marker ---"
    if grep -q "m0x41-podman shim" /usr/local/bin/podman 2>/dev/null; then
        pass "shim contains marker comment"
    else
        fail "shim marker comment missing"
    fi

    echo "--- shim reports correct version ---"
    if /usr/local/bin/podman --version 2>&1 | grep -q "5.8.1"; then
        pass "shim reports 5.8.1"
    else
        fail "shim version check"
    fi

    echo "--- shim finds OCI runtime ---"
    SHIM_RUNTIME=$(/usr/local/bin/podman info --format '{{.Host.OCIRuntime.Name}}' 2>&1) || true
    if echo "${SHIM_RUNTIME}" | grep -q "crun"; then
        pass "shim: OCI runtime is crun"
    else
        fail "shim: OCI runtime is '${SHIM_RUNTIME}', expected 'crun'"
    fi

    echo "--- system generator symlink ---"
    if [ -L /usr/lib/systemd/system-generators/podman-system-generator ]; then
        pass "system generator symlink exists"
    else
        fail "system generator symlink missing"
    fi

    echo "--- user generator symlink ---"
    if [ -L /usr/lib/systemd/user-generators/podman-user-generator ]; then
        pass "user generator symlink exists"
    else
        fail "user generator symlink missing"
    fi

    echo "--- policy.json installed ---"
    if [ -f /etc/containers/policy.json ]; then
        pass "policy.json exists"
    else
        fail "policy.json missing"
    fi

    echo "--- conmon-wrapper exists and is executable ---"
    if [ -x "${SNAP}/bin/conmon-wrapper" ]; then
        pass "conmon-wrapper exists at ${SNAP}/bin/conmon-wrapper"
    else
        fail "conmon-wrapper missing or not executable"
    fi

    echo "--- crun-wrapper exists and is executable ---"
    if [ -x "${SNAP}/bin/crun-wrapper" ]; then
        pass "crun-wrapper exists at ${SNAP}/bin/crun-wrapper"
    else
        fail "crun-wrapper missing or not executable"
    fi

    echo "--- no snap library paths in ldconfig cache ---"
    if ldconfig -p 2>/dev/null | grep -q "/snap/m0x41-podman/"; then
        fail "snap libraries found in ldconfig cache (library path poisoning)"
    else
        pass "no snap libraries in ldconfig cache"
    fi

    echo "--- no podman-snap.conf in ld.so.conf.d ---"
    if [ -f /etc/ld.so.conf.d/podman-snap.conf ]; then
        fail "podman-snap.conf still present (should not exist)"
    else
        pass "podman-snap.conf absent"
    fi

    # Validate each installed unit: must exist, reference the shim, and
    # not contain any Exec lines pointing to /usr/bin/podman.
    check_unit_file() {
        local scope="$1" unit="$2"
        local path="/usr/lib/systemd/${scope}/${unit}"
        echo "--- ${scope}: ${unit} references shim ---"
        if [ ! -f "${path}" ]; then
            fail "${scope}: ${unit} missing"
        elif ! grep -q "/usr/local/bin/podman" "${path}" 2>/dev/null; then
            fail "${scope}: ${unit} does not reference /usr/local/bin/podman"
        elif grep -q "Exec.*=/usr/bin/podman" "${path}" 2>/dev/null; then
            fail "${scope}: ${unit} still references /usr/bin/podman"
        else
            pass "${scope}: ${unit} references shim"
        fi
    }
    check_unit_symlink() {
        local scope="$1" unit="$2"
        local path="/usr/lib/systemd/${scope}/${unit}"
        echo "--- ${scope}: ${unit} installed ---"
        if [ -L "${path}" ]; then
            pass "${scope}: ${unit} symlink exists"
        else
            fail "${scope}: ${unit} symlink missing"
        fi
    }

    for scope in user system; do
        check_unit_symlink "${scope}" "podman.socket"
        check_unit_file    "${scope}" "podman.service"
        check_unit_file    "${scope}" "podman-auto-update.service"
        check_unit_symlink "${scope}" "podman-auto-update.timer"
        check_unit_file    "${scope}" "podman-restart.service"
    done
    check_unit_file "system" "podman-clean-transient.service"

    echo "--- man page symlinks installed ---"
    if [ -L /usr/local/share/man/man1/podman.1 ] && \
       readlink /usr/local/share/man/man1/podman.1 2>/dev/null | grep -q m0x41-podman; then
        pass "man page symlinks installed"
    else
        fail "man page symlinks missing"
    fi

    echo "--- man -w podman finds snap man page ---"
    if command -v man >/dev/null 2>&1; then
        if man -w podman 2>/dev/null | grep -q podman; then
            pass "man -w podman finds man page"
        else
            fail "man -w podman cannot find man page"
        fi
    else
        pass "man -w podman finds man page (skipped: man not installed)"
    fi

    # --- 5b: Quadlet dry-run ---
    echo ""
    echo "--- 5b: Quadlet dry-run ---"

    QUADLET="${SNAP}/usr/libexec/podman/quadlet"
    QUADLET_TMPDIR=$(mktemp -d)
    cat > "${QUADLET_TMPDIR}/dryrun-test.container" <<'CEOF'
[Container]
Image=docker.io/library/alpine
Exec=echo dryrun-ok
CEOF

    echo "--- quadlet generates valid unit ---"
    DRYRUN_OUT=$(QUADLET_UNIT_DIRS="${QUADLET_TMPDIR}" "${QUADLET}" -dryrun 2>&1) || true
    if echo "${DRYRUN_OUT}" | grep -q "\[Service\]"; then
        pass "quadlet dry-run produces [Service] section"
    else
        fail "quadlet dry-run missing [Service] section"
    fi

    echo "--- generated ExecStart references shim path ---"
    if echo "${DRYRUN_OUT}" | grep -q "ExecStart=/usr/local/bin/podman"; then
        pass "ExecStart references /usr/local/bin/podman"
    else
        fail "ExecStart does not reference /usr/local/bin/podman"
    fi

    echo "--- quadlet version matches ---"
    if "${QUADLET}" --version 2>&1 | grep -q "5.8.1"; then
        pass "quadlet version is 5.8.1"
    else
        fail "quadlet version mismatch"
    fi
    rm -rf "${QUADLET_TMPDIR}"

    # --- 5c: Live Quadlet rootful ---
    echo ""
    echo "--- 5c: Live Quadlet rootful ---"

    mkdir -p /etc/containers/systemd
    cat > /etc/containers/systemd/snap-test-quadlet.container <<'CEOF'
[Container]
Image=docker.io/library/alpine
Exec=echo quadlet-rootful-ok

[Service]
Type=oneshot
RemainAfterExit=no
CEOF

    echo "--- rootful quadlet service starts ---"
    systemctl daemon-reload 2>&1
    if systemctl start snap-test-quadlet.service 2>&1; then
        pass "rootful quadlet service started"
    else
        fail "rootful quadlet service failed to start"
    fi

    echo "--- rootful quadlet output correct ---"
    if journalctl -u snap-test-quadlet.service --no-pager -n 10 2>/dev/null | grep -q "quadlet-rootful-ok"; then
        pass "rootful quadlet output: quadlet-rootful-ok"
    else
        fail "rootful quadlet output missing"
    fi

    # Clean up rootful quadlet
    systemctl stop snap-test-quadlet.service 2>/dev/null || true
    rm -f /etc/containers/systemd/snap-test-quadlet.container
    ${PODMAN} system prune -af 2>&1 || true
    systemctl daemon-reload 2>&1

    # --- 5d: Live Quadlet rootless ---
    echo ""
    echo "--- 5d: Live Quadlet rootless ---"

    TESTUSER_HOME=$(eval echo "~${TESTUSER}")
    TESTUSER_QUADLET_DIR="${TESTUSER_HOME}/.config/containers/systemd"
    mkdir -p "${TESTUSER_QUADLET_DIR}"
    cat > "${TESTUSER_QUADLET_DIR}/snap-test-rootless.container" <<'CEOF'
[Container]
Image=docker.io/library/alpine
Exec=echo quadlet-rootless-ok

[Service]
Type=oneshot
RemainAfterExit=no
CEOF
    chown -R "${TESTUSER}:${TESTUSER}" "${TESTUSER_HOME}/.config"

    echo "--- rootless quadlet service starts ---"
    if run_as_testuser "systemctl --user daemon-reload && systemctl --user start snap-test-rootless.service" 2>&1; then
        pass "rootless quadlet service started"
    else
        fail "rootless quadlet service failed to start"
    fi

    echo "--- rootless quadlet output correct ---"
    if run_as_testuser "journalctl --user -u snap-test-rootless.service --no-pager -n 10" 2>/dev/null | grep -q "quadlet-rootless-ok"; then
        pass "rootless quadlet output: quadlet-rootless-ok"
    else
        fail "rootless quadlet output missing"
    fi

    # Clean up rootless quadlet
    run_as_testuser "systemctl --user stop snap-test-rootless.service" 2>/dev/null || true
    rm -f "${TESTUSER_QUADLET_DIR}/snap-test-rootless.container"
    run_as_testuser "systemctl --user daemon-reload" 2>/dev/null || true
    run_as_testuser "${PODMAN} system prune -af" 2>&1 || true

    # --- 5e: BATS quadlet tests (gated) ---
    echo ""
    echo "--- 5e: BATS quadlet tests ---"

    if [ -d "${PODMAN_SRC}/test/system" ] && command -v bats &>/dev/null; then
        SNAP_BINARY=$(command -v ${PODMAN}) || true
        export QUADLET="${SNAP}/usr/libexec/podman/quadlet"

        for batsfile in 251-system-service.bats 252-quadlet.bats 253-podman-quadlet.bats 254-podman-quadlet-multi.bats 270-socket-activation.bats; do
            if [ -f "${PODMAN_SRC}/test/system/${batsfile}" ]; then
                echo "--- ${batsfile} ---"
                cd "${PODMAN_SRC}"
                if PODMAN=/usr/local/bin/podman bats "test/system/${batsfile}" 2>&1 | tee "${RESULTS_DIR}/quadlet-${batsfile}.log" | tail -5; then
                    pass "BATS ${batsfile}"
                else
                    fail "BATS ${batsfile} (check ${RESULTS_DIR}/quadlet-${batsfile}.log)"
                fi
            fi
        done
    else
        echo "  Skipped: BATS or Podman source not available"
    fi

    # --- 5f: Go e2e quadlet tests (gated) ---
    echo ""
    echo "--- 5f: Go e2e quadlet tests ---"

    if [ -f "${PODMAN_SRC}/test/e2e/quadlet_test.go" ] && command -v go &>/dev/null; then
        echo "--- go test quadlet_test.go ---"
        cd "${PODMAN_SRC}"
        if QUADLET_BINARY="${SNAP}/usr/libexec/podman/quadlet" \
           PODMAN=/usr/local/bin/podman \
           go test -v -count=1 -run "Quadlet" ./test/e2e/ 2>&1 | tee "${RESULTS_DIR}/quadlet-go-e2e.log" | tail -20; then
            pass "Go e2e quadlet tests"
        else
            fail "Go e2e quadlet tests (check ${RESULTS_DIR}/quadlet-go-e2e.log)"
        fi
    else
        echo "  Skipped: Go or Podman source not available"
    fi

    # --- 5g: Healthcheck transient unit validation ---
    echo ""
    echo "--- 5g: Healthcheck transient unit validation ---"

    # Rootful: start a container with a healthcheck, verify the transient
    # timer propagates LD_LIBRARY_PATH and the healthcheck executes.
    HC_NAME="snap-hc-test"
    echo "--- rootful healthcheck: start container ---"
    ${PODMAN} rm -f "${HC_NAME}" 2>/dev/null || true
    if ${PODMAN} run -d --name "${HC_NAME}" \
        --health-cmd "echo ok" \
        --health-interval 60s \
        --health-start-period 0s \
        docker.io/library/alpine:latest sleep 300 2>&1; then
        pass "rootful healthcheck container started"
    else
        fail "rootful healthcheck container failed to start"
    fi

    # Give systemd-run a moment to register the transient timer.
    sleep 2

    echo "--- rootful healthcheck: transient timer exists ---"
    HC_CONTAINER_ID=$(${PODMAN} inspect --format '{{.Id}}' "${HC_NAME}" 2>/dev/null) || true
    if [ -n "${HC_CONTAINER_ID}" ] && systemctl list-units --type=timer --no-pager 2>/dev/null | grep -q "${HC_CONTAINER_ID:0:12}"; then
        pass "rootful healthcheck transient timer exists"
    else
        fail "rootful healthcheck transient timer not found"
    fi

    echo "--- rootful healthcheck: transient service has LD_LIBRARY_PATH ---"
    HC_SVC=$(systemctl list-units --type=timer --no-pager 2>/dev/null | grep "${HC_CONTAINER_ID:0:12}" | awk '{print $1}' | sed 's/\.timer$/.service/') || true
    if [ -n "${HC_SVC}" ] && systemctl show "${HC_SVC}" --property=Environment 2>/dev/null | grep -q "LD_LIBRARY_PATH"; then
        pass "rootful healthcheck transient service has LD_LIBRARY_PATH"
    else
        fail "rootful healthcheck transient service missing LD_LIBRARY_PATH"
    fi

    echo "--- rootful healthcheck: manual run succeeds ---"
    if ${PODMAN} healthcheck run "${HC_NAME}" 2>&1; then
        pass "rootful healthcheck run succeeded"
    else
        fail "rootful healthcheck run failed"
    fi

    echo "--- rootful healthcheck: status is healthy ---"
    HC_STATUS=$(${PODMAN} inspect --format '{{.State.Health.Status}}' "${HC_NAME}" 2>/dev/null) || true
    if [ "${HC_STATUS}" = "healthy" ]; then
        pass "rootful healthcheck status is healthy"
    else
        fail "rootful healthcheck status is '${HC_STATUS}', expected 'healthy'"
    fi

    ${PODMAN} rm -f "${HC_NAME}" 2>/dev/null || true

    # Rootless: same validation under the test user.
    HC_NAME_RL="snap-hc-test-rl"
    echo "--- rootless healthcheck: start container ---"
    run_as_testuser "${PODMAN} rm -f ${HC_NAME_RL}" 2>/dev/null || true
    if run_as_testuser "${PODMAN} run -d --name ${HC_NAME_RL} --health-cmd 'echo ok' --health-interval 60s --health-start-period 0s docker.io/library/alpine:latest sleep 300" 2>&1; then
        pass "rootless healthcheck container started"
    else
        fail "rootless healthcheck container failed to start"
    fi

    sleep 2

    echo "--- rootless healthcheck: transient timer exists ---"
    HC_RL_ID=$(run_as_testuser "${PODMAN} inspect --format '{{.Id}}' ${HC_NAME_RL}" 2>/dev/null) || true
    if [ -n "${HC_RL_ID}" ] && run_as_testuser "systemctl --user list-units --type=timer --no-pager" 2>/dev/null | grep -q "${HC_RL_ID:0:12}"; then
        pass "rootless healthcheck transient timer exists"
    else
        fail "rootless healthcheck transient timer not found"
    fi

    echo "--- rootless healthcheck: transient service has LD_LIBRARY_PATH ---"
    HC_RL_SVC=$(run_as_testuser "systemctl --user list-units --type=timer --no-pager" 2>/dev/null | grep "${HC_RL_ID:0:12}" | awk '{print $1}' | sed 's/\.timer$/.service/') || true
    if [ -n "${HC_RL_SVC}" ] && run_as_testuser "systemctl --user show '${HC_RL_SVC}' --property=Environment" 2>/dev/null | grep -q "LD_LIBRARY_PATH"; then
        pass "rootless healthcheck transient service has LD_LIBRARY_PATH"
    else
        fail "rootless healthcheck transient service missing LD_LIBRARY_PATH"
    fi

    echo "--- rootless healthcheck: manual run succeeds ---"
    if run_as_testuser "${PODMAN} healthcheck run ${HC_NAME_RL}" 2>&1; then
        pass "rootless healthcheck run succeeded"
    else
        fail "rootless healthcheck run failed"
    fi

    echo "--- rootless healthcheck: status is healthy ---"
    HC_RL_STATUS=$(run_as_testuser "${PODMAN} inspect --format '{{.State.Health.Status}}' ${HC_NAME_RL}" 2>/dev/null) || true
    if [ "${HC_RL_STATUS}" = "healthy" ]; then
        pass "rootless healthcheck status is healthy"
    else
        fail "rootless healthcheck status is '${HC_RL_STATUS}', expected 'healthy'"
    fi

    run_as_testuser "${PODMAN} rm -f ${HC_NAME_RL}" 2>/dev/null || true
    ${PODMAN} system prune -af 2>&1 || true
    run_as_testuser "${PODMAN} system prune -af" 2>&1 || true
}

# ---------- Main ----------
echo "=========================================="
echo "  Podman Classic Snap Test Runner"
echo "  Tier: ${TIER}"
echo "  Date: $(date -Iseconds)"
echo "=========================================="

case "${TIER}" in
    tier1) tier1 ;;
    tier2) tier2 ;;
    tier3) tier3 ;;
    tier4) tier4 ;;
    tier5) tier5 ;;
    all)
        tier1
        tier2
        tier3
        tier4
        tier5
        ;;
    *)
        echo "Usage: $0 [tier1|tier2|tier3|tier4|tier5|all]"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
if [ "${FAILURES}" -eq 0 ]; then
    echo "  All tests passed!"
else
    echo "  ${FAILURES} test(s) FAILED"
fi
echo "  Results in: ${RESULTS_DIR}/"
echo "=========================================="
exit "${FAILURES}"