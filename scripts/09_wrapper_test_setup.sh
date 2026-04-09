#!/bin/bash
# 09_wrapper_test_setup.sh — Runs INSIDE the LXD container as root
# Minimal setup for wrapper dependency detection tests.
# Deliberately does NOT install uidmap, dbus-user-session, or libgpg-error
# so that the wrapper's missing-dependency logic can be tested.
set -euo pipefail

SNAP="/snap/m0x41-podman/current"
SNAP_FILE="/root/m0x41-podman.snap"
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

# ---------- Phase 2: Install snapd only (no dependency packages) ----------
echo "=== Phase 2: Install snapd (no rootless deps) ==="

case "${ID}" in
    ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # Only snapd — no uidmap, no dbus-user-session
        apt-get install -y -qq snapd 2>&1 | tail -5

        if [ "${VERSION_ID}" = "20.04" ]; then
            echo "Refreshing snapd on Ubuntu 20.04..."
            snap refresh snapd 2>&1 || true
        fi
        ;;

    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # squashfuse required for snapd in LXD containers
        # No uidmap, no dbus-user-session, no iptables
        apt-get install -y -qq snapd squashfuse fuse 2>&1 | tail -5

        if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
            echo 1 > /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true
        fi

        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        echo "Waiting for snapd to initialise..."
        sleep 10
        snap wait system seed.loaded 2>/dev/null || true
        ;;

    fedora)
        dnf install -y snapd 2>&1 | tail -5
        # libgpg-error is a hard dependency — the snap binary won't load without it.
        # This is NOT a rootless dep; it's required for any mode.
        dnf install -y libgpg-error 2>&1 | tail -3
        # No shadow-utils, no iptables-nft

        setenforce 0 2>/dev/null || true
        ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true

        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd.service 2>/dev/null || true
        sleep 5
        snap wait system seed.loaded 2>/dev/null || true
        ;;

    centos|rocky|almalinux|rhel)
        dnf install -y epel-release 2>&1 | tail -3
        dnf install -y snapd 2>&1 | tail -5
        # libgpg-error is a hard dependency — the snap binary won't load without it.
        dnf install -y libgpg-error 2>&1 | tail -3
        # No shadow-utils, no iptables-nft

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

# ---------- Phase 3: Configure PATH ----------
echo "=== Phase 3: Configure PATH ==="
echo 'export PATH="/snap/bin:$PATH"' > /etc/profile.d/snap-path.sh
export PATH="/snap/bin:$PATH"

# ---------- Phase 4: Install snap ----------
echo "=== Phase 4: Install snap (classic) ==="
snap wait system seed.loaded 2>/dev/null || true
snap install "${SNAP_FILE}" --dangerous --classic

if ! m0x41-podman --version 2>&1; then
    echo "ERROR: snap binary fails to execute"
    exit 1
fi

# ---------- Phase 5: Create test user ----------
echo "=== Phase 5: Create test user ==="
if ! id "${TESTUSER}" &>/dev/null; then
    useradd -m -s /bin/bash "${TESTUSER}"

    # Write subuid/subgid directly (usermod --add-subuids may not be available
    # on distros where we deliberately skipped shadow-utils)
    echo "${TESTUSER}:100000:65536" >> /etc/subuid
    echo "${TESTUSER}:100000:65536" >> /etc/subgid

    loginctl enable-linger "${TESTUSER}" 2>/dev/null || true
fi

TESTUSER_UID=$(id -u "${TESTUSER}")

# ---------- Phase 6: Configure policy ----------
echo "=== Phase 6: Configure policy ==="

# Place policy.json at the standard system location.
mkdir -p /etc/containers
cp "${SNAP}/etc/containers/policy.json" /etc/containers/policy.json

# Disable AppArmor userns restriction if present (Ubuntu 24.04+)
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true
fi

# ---------- Phase 7: Write install_deps.sh helper ----------
echo "=== Phase 7: Write install_deps.sh helper ==="

cat > /root/install_deps.sh <<'DEPSEOF'
#!/bin/bash
# Installs the missing rootless dependencies for the detected distro.
set -euo pipefail
. /etc/os-release
case "${ID}" in
    ubuntu|debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq uidmap dbus-user-session 2>&1 | tail -5
        ;;
    fedora)
        dnf install -y shadow-utils 2>&1 | tail -3
        ;;
    centos|rocky|almalinux|rhel)
        dnf install -y shadow-utils 2>&1 | tail -3
        ;;
esac
echo "Dependencies installed."
DEPSEOF
chmod +x /root/install_deps.sh

echo ""
echo "=== Setup complete (minimal — no rootless deps) ==="
echo "  Distro: ${ID} ${VERSION_ID:-rolling}"
echo "  Snap: $(m0x41-podman --version 2>&1)"
echo "  Test user: ${TESTUSER} (uid ${TESTUSER_UID})"
echo "  Subuids: $(grep "^${TESTUSER}:" /etc/subuid 2>/dev/null || echo 'not found')"
echo "  install_deps.sh: /root/install_deps.sh"
