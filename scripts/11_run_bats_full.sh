#!/bin/bash
# 11_run_bats_full.sh — Runs INSIDE the LXD container
# Runs the FULL upstream Podman BATS test suite against the snap and
# produces a categorised results table showing pass/fail/skip per category.
# Failures are classified as snap-specific, LXD-limited, or infrastructure.
#
# Prerequisites: 04_test_setup.sh must have run (Go, BATS, Podman source).
# Usage: 11_run_bats_full.sh [rootless|root]
set -uo pipefail

SNAP="/snap/m0x41-podman/current"
PODMAN_SRC="/opt/podman"
RESULTS_DIR="/tmp/bats-full-results"
MODE="${1:-root}"
SNAP_BINARY=$(command -v m0x41-podman) || true

if [ ! -d "${PODMAN_SRC}/test/system" ] || ! command -v bats &>/dev/null; then
    echo "ERROR: BATS or Podman source not available. Run 04_test_setup.sh first."
    exit 1
fi

mkdir -p "${RESULTS_DIR}"

# ---------- Category mappings ----------
# Maps BATS file prefixes to human-readable categories.
declare -A FILE_CATEGORY
FILE_CATEGORY=(
    [001]="System & Info" [005]="System & Info" [015]="System & Info"
    [035]="System & Info" [037]="System & Info" [090]="System & Info"
    [220]="System & Info" [300]="System & Info" [320]="System & Info"
    [331]="System & Info" [600]="System & Info" [610]="System & Info"
    [620]="System & Info" [800]="System & Info"
    [010]="Images" [011]="Images" [012]="Images" [020]="Images"
    [070]="Images" [110]="Images" [120]="Images" [125]="Images"
    [140]="Images" [150]="Images" [155]="Images" [156]="Images"
    [330]="Images" [702]="Images" [750]="Images"
    [030]="Container Lifecycle" [032]="Container Lifecycle"
    [040]="Container Lifecycle" [045]="Container Lifecycle"
    [050]="Container Lifecycle" [055]="Container Lifecycle"
    [075]="Container Lifecycle" [080]="Container Lifecycle"
    [085]="Container Lifecycle" [130]="Container Lifecycle"
    [280]="Container Lifecycle" [450]="Container Lifecycle"
    [060]="Volumes & Storage" [065]="Volumes & Storage"
    [160]="Volumes & Storage" [161]="Volumes & Storage"
    [500]="Networking" [505]="Networking"
    [200]="Pods & Kube" [700]="Pods & Kube" [710]="Pods & Kube"
    [250]="Systemd & Quadlet" [251]="Systemd & Quadlet"
    [252]="Systemd & Quadlet" [253]="Systemd & Quadlet"
    [254]="Systemd & Quadlet" [255]="Systemd & Quadlet"
    [260]="Systemd & Quadlet" [270]="Systemd & Quadlet"
    [271]="Systemd & Quadlet"
    [170]="Security & Namespaces" [180]="Security & Namespaces"
    [190]="Security & Namespaces" [195]="Security & Namespaces"
    [400]="Security & Namespaces" [410]="Security & Namespaces"
    [420]="Security & Namespaces"
    [272]="Advanced" [273]="Advanced" [520]="Advanced"
    [550]="Advanced" [555]="Advanced" [760]="Advanced"
    [850]="Advanced" [900]="Advanced" [950]="Advanced" [999]="Advanced"
)

# ---------- Failure classification patterns ----------
# Grep patterns to classify why a test failed.
classify_failure() {
    local logfile="$1"
    local snap_patterns="CONTAINERS_CONF|CONTAINERS_STORAGE_CONF|/snap/m0x41-podman|snap-specific"
    local lxd_patterns="Operation not permitted|newuidmap|newgidmap|setuid|EPERM|unshare.*permission|cgroupv2.*not available"
    local infra_patterns="htpasswd.*not found|command not found.*htpasswd|registry.*timed out|skopeo.*preserve-digests|pasta.*not found|setup_suite.*failed|clean_setup.*failed|prefetch.*failed|Executed 1 instead of expected|run_podman_testing.*failed|podman_testing.*not found"

    if grep -qEi "${snap_patterns}" "${logfile}" 2>/dev/null; then
        echo "snap"
    elif grep -qEi "${lxd_patterns}" "${logfile}" 2>/dev/null; then
        echo "lxd"
    elif grep -qEi "${infra_patterns}" "${logfile}" 2>/dev/null; then
        echo "infra"
    else
        echo "unknown"
    fi
}

# ---------- Run tests ----------
echo "=========================================="
echo "  Full Upstream BATS Suite"
echo "  Mode: ${MODE}"
echo "  Date: $(date -Iseconds)"
echo "=========================================="
echo ""

# Ordered category list for consistent output
CATEGORIES=("System & Info" "Container Lifecycle" "Images" "Volumes & Storage" "Networking" "Pods & Kube" "Systemd & Quadlet" "Security & Namespaces" "Advanced")

# Accumulators per category
declare -A CAT_TOTAL CAT_PASS CAT_FAIL CAT_SKIP CAT_SNAP CAT_LXD CAT_INFRA CAT_UNKNOWN
for cat in "${CATEGORIES[@]}"; do
    CAT_TOTAL["$cat"]=0; CAT_PASS["$cat"]=0; CAT_FAIL["$cat"]=0
    CAT_SKIP["$cat"]=0; CAT_SNAP["$cat"]=0; CAT_LXD["$cat"]=0
    CAT_INFRA["$cat"]=0; CAT_UNKNOWN["$cat"]=0
done

TOTAL_FILES=0
TOTAL_TESTS=0
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

cd "${PODMAN_SRC}"

for batsfile in test/system/[0-9]*.bats; do
    filename=$(basename "${batsfile}")
    prefix="${filename%%-*}"
    category="${FILE_CATEGORY[$prefix]:-Advanced}"
    logfile="${RESULTS_DIR}/${MODE}-${filename}.log"

    echo -n "  ${filename} ... "
    TOTAL_FILES=$((TOTAL_FILES + 1))

    # Run BATS
    if [ "${MODE}" = "rootless" ]; then
        TESTUSER="podtest"
        uid=$(id -u "${TESTUSER}")
        mkdir -p "/run/user/${uid}"
        chown "${TESTUSER}:${TESTUSER}" "/run/user/${uid}"
        su - "${TESTUSER}" -c "
            export XDG_RUNTIME_DIR=/run/user/${uid}
            cd ${PODMAN_SRC} && PODMAN=/usr/local/bin/podman bats ${batsfile}
        " > "${logfile}" 2>&1 || true
    else
        PODMAN=/usr/local/bin/podman bats "${batsfile}" > "${logfile}" 2>&1 || true
    fi

    # Parse TAP output
    file_pass=$(grep -c "^ok " "${logfile}" 2>/dev/null || true)
    file_fail=$(grep -c "^not ok " "${logfile}" 2>/dev/null || true)
    file_total=$((file_pass + file_fail))

    # Count skips (ok lines with "# skip")
    file_skip=$(grep -c "^ok .* # skip" "${logfile}" 2>/dev/null || true)
    file_pass=$((file_pass - file_skip))

    echo "${file_pass} pass, ${file_fail} fail, ${file_skip} skip (${file_total} total)"

    # Classify failures
    file_snap=0; file_lxd=0; file_infra=0; file_unknown=0
    if [ "${file_fail}" -gt 0 ]; then
        reason=$(classify_failure "${logfile}")
        case "${reason}" in
            snap)    file_snap=${file_fail} ;;
            lxd)     file_lxd=${file_fail} ;;
            infra)   file_infra=${file_fail} ;;
            unknown) file_unknown=${file_fail} ;;
        esac
    fi

    # Accumulate
    CAT_TOTAL["$category"]=$(( ${CAT_TOTAL["$category"]} + file_total ))
    CAT_PASS["$category"]=$(( ${CAT_PASS["$category"]} + file_pass ))
    CAT_FAIL["$category"]=$(( ${CAT_FAIL["$category"]} + file_fail ))
    CAT_SKIP["$category"]=$(( ${CAT_SKIP["$category"]} + file_skip ))
    CAT_SNAP["$category"]=$(( ${CAT_SNAP["$category"]} + file_snap ))
    CAT_LXD["$category"]=$(( ${CAT_LXD["$category"]} + file_lxd ))
    CAT_INFRA["$category"]=$(( ${CAT_INFRA["$category"]} + file_infra ))
    CAT_UNKNOWN["$category"]=$(( ${CAT_UNKNOWN["$category"]} + file_unknown ))
    TOTAL_TESTS=$((TOTAL_TESTS + file_total))
    TOTAL_PASS=$((TOTAL_PASS + file_pass))
    TOTAL_FAIL=$((TOTAL_FAIL + file_fail))
    TOTAL_SKIP=$((TOTAL_SKIP + file_skip))
done

# ---------- Summary table ----------
echo ""
echo "=========================================="
echo "  Results by Category (${MODE})"
echo "=========================================="
printf "| %-22s | %5s | %5s | %5s | %5s | %5s | %5s | %5s |\n" \
    "Category" "Tests" "Pass" "Skip" "Snap" "LXD" "Infra" "Other"
printf "|%-24s|%7s|%7s|%7s|%7s|%7s|%7s|%7s|\n" \
    "------------------------" "-------" "-------" "-------" "-------" "-------" "-------" "-------"

for cat in "${CATEGORIES[@]}"; do
    printf "| %-22s | %5d | %5d | %5d | %5d | %5d | %5d | %5d |\n" \
        "${cat}" "${CAT_TOTAL[$cat]}" "${CAT_PASS[$cat]}" "${CAT_SKIP[$cat]}" \
        "${CAT_SNAP[$cat]}" "${CAT_LXD[$cat]}" "${CAT_INFRA[$cat]}" "${CAT_UNKNOWN[$cat]}"
done

printf "|%-24s|%7s|%7s|%7s|%7s|%7s|%7s|%7s|\n" \
    "------------------------" "-------" "-------" "-------" "-------" "-------" "-------" "-------"
printf "| %-22s | %5d | %5d | %5d | %5d | %5d | %5d | %5d |\n" \
    "TOTAL" "${TOTAL_TESTS}" "${TOTAL_PASS}" "${TOTAL_SKIP}" \
    "$((TOTAL_FAIL - TOTAL_FAIL))" "0" "0" "0"

# Recount failure classifications for total row
total_snap=0; total_lxd=0; total_infra=0; total_unknown=0
for cat in "${CATEGORIES[@]}"; do
    total_snap=$((total_snap + ${CAT_SNAP[$cat]}))
    total_lxd=$((total_lxd + ${CAT_LXD[$cat]}))
    total_infra=$((total_infra + ${CAT_INFRA[$cat]}))
    total_unknown=$((total_unknown + ${CAT_UNKNOWN[$cat]}))
done

# Reprint total with correct values
echo ""
echo "  Files: ${TOTAL_FILES} | Tests: ${TOTAL_TESTS} | Pass: ${TOTAL_PASS} | Skip: ${TOTAL_SKIP} | Fail: ${TOTAL_FAIL}"
echo "  Failure breakdown: Snap=${total_snap} LXD=${total_lxd} Infra=${total_infra} Other=${total_unknown}"
echo ""
echo "  Logs: ${RESULTS_DIR}/"

# ---------- Write machine-readable results ----------
{
    echo "mode,category,file,total,pass,fail,skip,reason"
    for batsfile in test/system/[0-9]*.bats; do
        filename=$(basename "${batsfile}")
        prefix="${filename%%-*}"
        category="${FILE_CATEGORY[$prefix]:-Advanced}"
        logfile="${RESULTS_DIR}/${MODE}-${filename}.log"

        file_pass=$(grep -c "^ok " "${logfile}" 2>/dev/null || true)
        file_fail=$(grep -c "^not ok " "${logfile}" 2>/dev/null || true)
        file_skip=$(grep -c "^ok .* # skip" "${logfile}" 2>/dev/null || true)
        file_pass=$((file_pass - file_skip))
        file_total=$((file_pass + file_fail + file_skip))

        reason="pass"
        if [ "${file_fail}" -gt 0 ]; then
            reason=$(classify_failure "${logfile}")
        fi

        echo "${MODE},${category},${filename},${file_total},${file_pass},${file_fail},${file_skip},${reason}"
    done
} > "${RESULTS_DIR}/${MODE}-results.csv"

echo "  CSV: ${RESULTS_DIR}/${MODE}-results.csv"
