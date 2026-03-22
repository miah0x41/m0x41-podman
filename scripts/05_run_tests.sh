#!/bin/bash
# 05_run_tests.sh — Runs INSIDE the LXD container
# Tests snap-installed Podman via `snap run` (classic confinement).
# Usage: 05_run_tests.sh [tier1|tier2|tier3|tier4|all]
#
# All tests use `podman-m0x41` (i.e. snap run). Classic confinement
# means the snap command sees the real host filesystem — no bypass needed.
set -euo pipefail

SNAP="/snap/podman-m0x41/current"
PODMAN="podman-m0x41"
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
    if echo "${CONMON}" | grep -q "/snap/podman-m0x41/"; then
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
    TMPDIR=$(mktemp -d)
    cat > "${TMPDIR}/Containerfile" <<'CEOF'
FROM docker.io/library/alpine:latest
RUN echo "built by classic snap podman" > /built.txt
CMD cat /built.txt
CEOF
    chown -R "${TESTUSER}:${TESTUSER}" "${TMPDIR}"
    if run_as_testuser "${PODMAN} build -t snap-test ${TMPDIR}" 2>&1; then
        pass "rootless image build"
    else
        fail "rootless image build"
    fi
    if run_as_testuser "${PODMAN} run --rm snap-test" 2>&1; then
        pass "rootless run built image"
    else
        fail "rootless run built image"
    fi
    rm -rf "${TMPDIR}"

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
    TMPDIR=$(mktemp -d)
    cat > "${TMPDIR}/Containerfile" <<'CEOF'
FROM docker.io/library/alpine:latest
RUN echo "built by rootful classic snap podman" > /built.txt
CMD cat /built.txt
CEOF
    if ${PODMAN} build -t snap-root-test "${TMPDIR}" 2>&1; then
        pass "rootful image build"
    else
        fail "rootful image build"
    fi
    if ${PODMAN} run --rm snap-root-test 2>&1; then
        pass "rootful run built image"
    else
        fail "rootful run built image"
    fi
    rm -rf "${TMPDIR}"

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
    all)
        tier1
        tier2
        tier3
        tier4
        ;;
    *)
        echo "Usage: $0 [tier1|tier2|tier3|tier4|all]"
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
