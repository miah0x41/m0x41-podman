#!/bin/bash
# 06_test_multi_distro.sh — Host-side orchestrator for multi-distro snap testing
# Runs all distros in parallel for faster results.
# Run from the host within `newgrp lxd`.
# Usage: ./scripts/06_test_multi_distro.sh [--cleanup] [tier1|tier2|tier3|all]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SNAP_FILE="${PROJECT_DIR}/m0x41-podman_5.8.1_amd64.snap"
RESULTS_FILE="${PROJECT_DIR}/multi-distro-results.txt"

# Test counts per tier (must match 05_run_tests.sh)
# Tier 5 count covers 5a-5d only (5e/5f gated on Go/BATS, not available in multi-distro)
TIER1_COUNT=7
TIER2_COUNT=8
TIER3_COUNT=6
TIER5_COUNT=20

# Parse args
CLEANUP=false
TIER="all"
for arg in "$@"; do
    case "${arg}" in
        --cleanup) CLEANUP=true ;;
        tier[1-5]|all) TIER="${arg}" ;;
        *) echo "Usage: $0 [--cleanup] [tier1|tier2|tier3|tier5|all]"; exit 1 ;;
    esac
done

if [ ! -f "${SNAP_FILE}" ]; then
    echo "ERROR: Snap file not found: ${SNAP_FILE}"
    echo "Build it first with: ./scripts/01_launch.sh"
    exit 1
fi

# Distro matrix — parallel indexed arrays
DISTRO_NAMES=(   "ubuntu-2204"   "ubuntu-2404"   "debian-12"         "fedora-42"         "centos-9"               )
DISTRO_IMAGES=(  "ubuntu:22.04"  "ubuntu:24.04"  "images:debian/12"  "images:fedora/42"  "images:centos/9-Stream" )

build_tiers_list() {
    case "${TIER}" in
        all) echo "tier1 tier2 tier3 tier5" ;;
        *)   echo "${TIER}" ;;
    esac
}

count_for_tier() {
    case "$1" in
        tier1) echo "${TIER1_COUNT}" ;;
        tier2) echo "${TIER2_COUNT}" ;;
        tier3) echo "${TIER3_COUNT}" ;;
        tier5) echo "${TIER5_COUNT}" ;;
        *)     echo "0" ;;
    esac
}

# Run a single tier and emit a result line
run_tier() {
    local container="$1" tier="$2"
    local total
    total=$(count_for_tier "${tier}")

    local output exit_code=0
    output=$(lxc exec "${container}" -- /root/05_run_tests.sh "${tier}" 2>&1) || exit_code=$?

    local passes failures
    passes=$(echo "${output}" | grep -c "^  PASS:" || true)
    failures=$(echo "${output}" | grep -c "^  FAIL:" || true)

    if [ "${exit_code}" -eq 0 ] && [ "${passes}" -eq "${total}" ]; then
        echo "${passes}/${total} pass"
    else
        echo "${passes}/${total} (${failures} fail)"
    fi
}

# Test a single distro end-to-end (runs in a subshell for parallel execution)
test_distro() {
    local name="$1" image="$2"
    local container="snap-test-22-${name}"
    local log="/tmp/multi-distro-22-${name}.log"

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
                echo "RESULT:${name}:LAUNCH FAIL:-:-:-:-"
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
            RESULT_LINE="RESULT:${name}:NET FAIL:-:-:-:-"
            echo "${RESULT_LINE}"
            if ${CLEANUP}; then lxc delete --force "${container}" 2>/dev/null || true; fi
            return
        fi

        # --- Push files ---
        echo "Pushing snap and scripts..."
        lxc file push "${SNAP_FILE}" "${container}/root/m0x41-podman_5.8.1_amd64.snap"
        lxc file push "${SCRIPT_DIR}/07_test_setup_multi.sh" "${container}/root/07_test_setup_multi.sh"
        lxc file push "${SCRIPT_DIR}/05_run_tests.sh" "${container}/root/05_run_tests.sh"
        lxc exec "${container}" -- chmod +x /root/07_test_setup_multi.sh /root/05_run_tests.sh

        # --- Run setup ---
        echo "Running setup..."
        if ! lxc exec "${container}" -- /root/07_test_setup_multi.sh 2>&1; then
            echo "RESULT:${name}:SETUP FAIL:-:-:-:-"
            if ${CLEANUP}; then lxc delete --force "${container}" 2>/dev/null || true; fi
            return
        fi

        # --- Run requested tiers ---
        local t1="-" t2="-" t3="-" t5="-"
        for t in $(build_tiers_list); do
            result=$(run_tier "${container}" "${t}")
            case "${t}" in
                tier1) t1="${result}" ;;
                tier2) t2="${result}" ;;
                tier3) t3="${result}" ;;
                tier5) t5="${result}" ;;
            esac
        done

        echo "RESULT:${name}:OK:${t1}:${t2}:${t3}:${t5}"

        if ${CLEANUP}; then
            echo "Cleaning up ${container}..."
            lxc delete --force "${container}" 2>/dev/null || true
        fi
    } > "${log}" 2>&1

    # Print result line to stdout for the summary
    grep "^RESULT:" "${log}" | tail -1
}

echo "=========================================="
echo "  Multi-Distribution Snap Test (core22)"
echo "  Tier: ${TIER}"
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
declare -A RESULTS
for pid in "${pids[@]}"; do
    wait $pid 2>/dev/null || true
done

# --- Print summary table ---
echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
    "Distro" "Setup" "Tier 1 (${TIER1_COUNT})" "Tier 2 (${TIER2_COUNT})" "Tier 3 (${TIER3_COUNT})" "Tier 5 (${TIER5_COUNT})"
printf "|%-18s|%-13s|%-16s|%-16s|%-16s|%-16s|\n" \
    "------------------" "-------------" "----------------" "----------------" "----------------" "----------------"

for i in "${!DISTRO_NAMES[@]}"; do
    name="${DISTRO_NAMES[$i]}"
    log="/tmp/multi-distro-22-${name}.log"
    line=$(grep "^RESULT:" "${log}" 2>/dev/null | tail -1)
    if [ -n "${line}" ]; then
        IFS=':' read -r _ dname setup t1 t2 t3 t5 <<< "${line}"
        printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
            "${dname}" "${setup}" "${t1}" "${t2}" "${t3}" "${t5}"
    else
        printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
            "${name}" "UNKNOWN" "-" "-" "-" "-"
    fi
done

# --- Write results file ---
{
    echo "Multi-Distribution Snap Test Results (core22)"
    echo "Date: $(date -Iseconds)"
    echo "Tier: ${TIER}"
    echo ""
    printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
        "Distro" "Setup" "Tier 1 (${TIER1_COUNT})" "Tier 2 (${TIER2_COUNT})" "Tier 3 (${TIER3_COUNT})" "Tier 5 (${TIER5_COUNT})"
    printf "|%-18s|%-13s|%-16s|%-16s|%-16s|%-16s|\n" \
        "------------------" "-------------" "----------------" "----------------" "----------------" "----------------"
    for i in "${!DISTRO_NAMES[@]}"; do
        name="${DISTRO_NAMES[$i]}"
        log="/tmp/multi-distro-22-${name}.log"
        line=$(grep "^RESULT:" "${log}" 2>/dev/null | tail -1)
        if [ -n "${line}" ]; then
            IFS=':' read -r _ dname setup t1 t2 t3 t5 <<< "${line}"
            printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
                "${dname}" "${setup}" "${t1}" "${t2}" "${t3}" "${t5}"
        else
            printf "| %-16s | %-11s | %-14s | %-14s | %-14s | %-14s |\n" \
                "${name}" "UNKNOWN" "-" "-" "-" "-"
        fi
    done
} > "${RESULTS_FILE}"

echo ""
echo "Results written to: ${RESULTS_FILE}"
echo "Per-distro logs in: /tmp/multi-distro-22-*.log"
