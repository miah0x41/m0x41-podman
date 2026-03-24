#!/bin/bash
# 07_test_setup_multi.sh — Runs INSIDE the LXD container as root
# Distro-agnostic setup for snap testing (tiers 1-3 only).
# Installs snapd, the snap (classic), creates test user, configures libraries.
set -euo pipefail

SNAP="/snap/m0x41-podman/current"
SNAP_FILE="/root/m0x41-podman_5.8.1_amd64.snap"
TESTUSER="podtest"

# ---------- Phase 1: Detect distro ----------
echo "=== Phase 1: Detect distribution ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "ERROR: /etc/os-release not found"
    exit 1
fi
echo "Detected: ${ID} ${VERSION_ID:-rolling}"

# ---------- Phase 2: Install snapd + prerequisites ----------
echo "=== Phase 2: Install snapd and prerequisites ==="

case "${ID}" in
    ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq uidmap dbus-user-session 2>&1 | tail -5

        # Ubuntu 20.04 ships snapd 2.54; core22 base needs >= 2.62
        if [ "${VERSION_ID}" = "20.04" ]; then
            echo "Refreshing snapd on Ubuntu 20.04..."
            snap refresh snapd 2>&1 || true
        fi
        ;;

    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # squashfuse required for snapd in LXD containers (can't mount squashfs natively)
        # iptables required by netavark for rootful container networking (not installed by default)
        apt-get install -y -qq snapd squashfuse fuse uidmap dbus-user-session iptables 2>&1 | tail -5

        # Enable unprivileged user namespaces if restricted
        if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
            echo 1 > /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true
        fi

        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        # Debian snapd needs extra time to initialise in LXD
        echo "Waiting for snapd to initialise..."
        sleep 10
        snap wait system seed.loaded 2>/dev/null || true
        ;;

    fedora)
        dnf install -y snapd 2>&1 | tail -5

        # shadow-utils: newuidmap/newgidmap; libgpg-error: snap bundles libgpgme but not this dep
        # iptables-nft: required by netavark for rootful container networking
        dnf install -y shadow-utils libgpg-error iptables-nft 2>&1 | tail -3

        # SELinux blocks snap operations
        setenforce 0 2>/dev/null || true

        # snapd expects /snap symlink on non-Ubuntu
        ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true

        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        sleep 5
        snap wait system seed.loaded 2>/dev/null || true
        ;;

    centos|rocky|almalinux|rhel)
        # EPEL provides snapd on CentOS/RHEL derivatives
        dnf install -y epel-release 2>&1 | tail -3
        dnf install -y snapd 2>&1 | tail -5
        # iptables-nft: required by netavark for rootful container networking
        dnf install -y shadow-utils libgpg-error iptables-nft 2>&1 | tail -3

        setenforce 0 2>/dev/null || true
        ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true

        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        sleep 5
        snap wait system seed.loaded 2>/dev/null || true
        ;;

    *)
        echo "ERROR: Unsupported distribution: ${ID}"
        exit 1
        ;;
esac

# ---------- Phase 3: Ensure /snap/bin on PATH ----------
echo "=== Phase 3: Configure PATH ==="
echo 'export PATH="/snap/bin:$PATH"' > /etc/profile.d/snap-path.sh
export PATH="/snap/bin:$PATH"

# ---------- Phase 4: Install snap ----------
echo "=== Phase 4: Install snap (classic) ==="
snap wait system seed.loaded 2>/dev/null || true
snap install "${SNAP_FILE}" --dangerous --classic

# Verify the binary actually works (catches glibc/lib mismatches)
if ! m0x41-podman --version 2>&1; then
    echo "ERROR: snap binary fails to execute — likely glibc or library incompatibility"
    exit 1
fi

# ---------- Phase 5: Create test user ----------
echo "=== Phase 5: Create test user ==="
if ! id "${TESTUSER}" &>/dev/null; then
    useradd -m -s /bin/bash "${TESTUSER}"

    # usermod --add-subuids is not available on all distros
    if usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${TESTUSER}" 2>/dev/null; then
        echo "Configured subuids via usermod"
    else
        echo "Falling back to manual subuid/subgid configuration"
        echo "${TESTUSER}:100000:65536" >> /etc/subuid
        echo "${TESTUSER}:100000:65536" >> /etc/subgid
    fi

    loginctl enable-linger "${TESTUSER}" 2>/dev/null || true
fi

TESTUSER_UID=$(id -u "${TESTUSER}")

# ---------- Phase 6: Verify install hook artefacts ----------
echo "=== Phase 6: Verify install hook artefacts ==="

# The snap install hook should have created these automatically.
HOOK_OK=true
test -f /usr/local/bin/podman && echo "  Shim: OK" || { echo "  WARNING: shim missing"; HOOK_OK=false; }
test -L /usr/lib/systemd/system-generators/podman-system-generator && echo "  System generator: OK" || { echo "  WARNING: system generator missing"; HOOK_OK=false; }
test -f /etc/containers/policy.json && echo "  policy.json: OK" || { echo "  WARNING: policy.json missing"; HOOK_OK=false; }
test -f /etc/ld.so.conf.d/podman-snap.conf && echo "  ldconfig conf: OK" || { echo "  WARNING: ldconfig conf missing"; HOOK_OK=false; }
if [ "${HOOK_OK}" = false ]; then
    echo "  Install hook may have failed — falling back to manual setup"
    printf '%s\n' "${SNAP}/usr/lib/x86_64-linux-gnu" "${SNAP}/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/podman-snap.conf
    ldconfig
    mkdir -p /etc/containers
    cp "${SNAP}/etc/containers/policy.json" /etc/containers/policy.json
fi

# Disable AppArmor userns restriction if present (Ubuntu 24.04+)
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true
fi

echo ""
echo "=== Setup complete ==="
echo "  Distro: ${ID} ${VERSION_ID:-rolling}"
echo "  Snap: $(m0x41-podman --version 2>&1)"
echo "  Test user: ${TESTUSER} (uid ${TESTUSER_UID})"
echo "  Subuids: $(grep "^${TESTUSER}:" /etc/subuid 2>/dev/null || echo 'not found')"
