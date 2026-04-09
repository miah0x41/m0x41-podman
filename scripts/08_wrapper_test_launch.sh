#!/bin/bash
# 08_wrapper_test_launch.sh — Host-side orchestrator for wrapper dependency tests
# Launches minimal containers per distro (no rootless deps installed),
# then runs the wrapper hello/dependency detection tests.
# Usage: ./scripts/08_wrapper_test_launch.sh [--cleanup]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GIT_SHORT=$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SNAP_FILE=$(ls -t "${PROJECT_DIR}"/m0x41-podman_*".g${GIT_SHORT}_"*.snap 2>/dev/null | head -1 || true)
RESULTS_FILE="${PROJECT_DIR}/wrapper-test-results.txt"

WRAPPER_TEST_COUNT=18

# Parse args
CLEANUP=false
for arg in "$@"; do
    case "${arg}" in
        --cleanup) CLEANUP=true ;;
        *) echo "Usage: $0 [--cleanup]"; exit 1 ;;
    esac
done

if [ -z "${SNAP_FILE}" ] || [ ! -f "${SNAP_FILE}" ]; then
    echo "ERROR: No snap matching HEAD (${GIT_SHORT}) in ${PROJECT_DIR}"
    echo "Build it first with: ./scripts/01_launch.sh"
    exit 1
fi
echo "Using snap: $(basename "${SNAP_FILE}")"

# Distro matrix
DISTRO_NAMES=(   "ubuntu-2204"   "ubuntu-2404"   "debian-12"         "fedora-43"         "centos-9"               )
DISTRO_IMAGES=(  "ubuntu:22.04"  "ubuntu:24.04"  "images:debian/12"  "images:fedora/43"  "images:centos/9-Stream" )

# Test a single distro end-to-end (runs in a subshell for parallel execution)
test_distro() {
    local name="$1" image="$2"
    local container="snap-wtest-22-${name}"
    local log="/tmp/wrapper-test-22-${name}.log"

    {
        echo "====== ${name} (${image}) ======"

        # --- Create container ---
        if lxc info "${container}" &>/dev/null; then
            echo "Container '${container}' already exists."
            STATE=$(lxc info "${container}" | grep "^Status:" | awk '{print $2}')
            if [ "${STATE}" != "RUNNING" ]; then
                lxc start "${container}"
            fi
        else
            echo "Launching ${image}..."
            if ! lxc launch "${image}" "${container}" \
                -c security.nesting=true \
                -c security.syscalls.intercept.mknod=true \
                -c security.syscalls.intercept.setxattr=true 2>&1; then
                echo "RESULT:${name}:LAUNCH FAIL:-"
                return
            fi
        fi

        # --- Wait for networking ---
        NET_OK=false
        for _ in $(seq 1 60); do
            if lxc exec "${container}" -- ping -c1 -W1 1.1.1.1 &>/dev/null; then
                NET_OK=true; break
            fi
            sleep 1
        done
        if ! ${NET_OK}; then
            echo "Networking failed after 60s"
            echo "RESULT:${name}:NET FAIL:-"
            if ${CLEANUP}; then lxc delete --force "${container}" 2>/dev/null || true; fi
            return
        fi

        # --- Push files ---
        echo "Pushing snap and scripts..."
        lxc file push "${SNAP_FILE}" "${container}/root/m0x41-podman.snap"
        lxc file push "${SCRIPT_DIR}/09_wrapper_test_setup.sh" "${container}/root/09_wrapper_test_setup.sh"
        lxc file push "${SCRIPT_DIR}/10_wrapper_tests.sh" "${container}/root/10_wrapper_tests.sh"
        lxc exec "${container}" -- chmod +x /root/09_wrapper_test_setup.sh /root/10_wrapper_tests.sh

        # --- Run setup ---
        echo "Running minimal setup (no rootless deps)..."
        if ! lxc exec "${container}" -- /root/09_wrapper_test_setup.sh 2>&1; then
            echo "RESULT:${name}:SETUP FAIL:-"
            if ${CLEANUP}; then lxc delete --force "${container}" 2>/dev/null || true; fi
            return
        fi

        # --- Run wrapper tests ---
        echo "Running wrapper tests..."
        local output exit_code=0
        output=$(lxc exec "${container}" -- /root/10_wrapper_tests.sh 2>&1) || exit_code=$?

        local passes failures
        passes=$(echo "${output}" | grep -c "^  PASS:" || true)
        failures=$(echo "${output}" | grep -c "^  FAIL:" || true)

        echo "${output}"

        if [ "${exit_code}" -eq 0 ] && [ "${failures}" -eq 0 ]; then
            echo "RESULT:${name}:OK:${passes}/${WRAPPER_TEST_COUNT} pass"
        else
            echo "RESULT:${name}:OK:${passes}/${WRAPPER_TEST_COUNT} (${failures} fail)"
        fi

        if ${CLEANUP}; then
            echo "Cleaning up ${container}..."
            lxc delete --force "${container}" 2>/dev/null || true
        fi
    } > "${log}" 2>&1

    # Print result line to stdout for the summary
    grep "^RESULT:" "${log}" | tail -1
}

echo "=========================================="
echo "  Wrapper Dependency Detection Tests"
echo "  Cleanup: ${CLEANUP}"
echo "  Parallel: yes"
echo "  Date: $(date -Iseconds)"
echo "=========================================="
echo ""

# --- Launch all distros in parallel ---
pids=()
for i in "${!DISTRO_NAMES[@]}"; do
    name="${DISTRO_NAMES[$i]}"
    image="${DISTRO_IMAGES[$i]}"
    echo "Starting ${name} (${image})..."
    test_distro "${name}" "${image}" &
    pids+=($!)
done

echo ""
echo "All ${#pids[@]} distros launched. Waiting for results..."
echo ""

# --- Collect results ---
for pid in "${pids[@]}"; do
    wait $pid 2>/dev/null || true
done

# --- Print summary table ---
echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
printf "| %-16s | %-11s | %-24s |\n" \
    "Distro" "Setup" "Wrapper Tests (${WRAPPER_TEST_COUNT})"
printf "|%-18s|%-13s|%-26s|\n" \
    "------------------" "-------------" "--------------------------"

for i in "${!DISTRO_NAMES[@]}"; do
    name="${DISTRO_NAMES[$i]}"
    log="/tmp/wrapper-test-22-${name}.log"
    line=$(grep "^RESULT:" "${log}" 2>/dev/null | tail -1)
    if [ -n "${line}" ]; then
        IFS=':' read -r _ dname setup result <<< "${line}"
        printf "| %-16s | %-11s | %-24s |\n" \
            "${dname}" "${setup}" "${result}"
    else
        printf "| %-16s | %-11s | %-24s |\n" \
            "${name}" "UNKNOWN" "-"
    fi
done

# --- Write results file ---
{
    echo "Wrapper Dependency Detection Test Results"
    echo "Date: $(date -Iseconds)"
    echo ""
    printf "| %-16s | %-11s | %-24s |\n" \
        "Distro" "Setup" "Wrapper Tests (${WRAPPER_TEST_COUNT})"
    printf "|%-18s|%-13s|%-26s|\n" \
        "------------------" "-------------" "--------------------------"
    for i in "${!DISTRO_NAMES[@]}"; do
        name="${DISTRO_NAMES[$i]}"
        log="/tmp/wrapper-test-22-${name}.log"
        line=$(grep "^RESULT:" "${log}" 2>/dev/null | tail -1)
        if [ -n "${line}" ]; then
            IFS=':' read -r _ dname setup result <<< "${line}"
            printf "| %-16s | %-11s | %-24s |\n" \
                "${dname}" "${setup}" "${result}"
        else
            printf "| %-16s | %-11s | %-24s |\n" \
                "${name}" "UNKNOWN" "-"
        fi
    done
} > "${RESULTS_FILE}"

echo ""
echo "Results written to: ${RESULTS_FILE}"
echo "Per-distro logs in: /tmp/wrapper-test-22-*.log"
