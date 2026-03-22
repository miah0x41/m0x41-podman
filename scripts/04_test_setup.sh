#!/bin/bash
# 04_test_setup.sh — Runs INSIDE the LXD container as root
# Installs the snap (classic), prerequisites, creates test user, and
# optionally installs Go/BATS/Podman source for tier4 BATS parity tests.
set -euo pipefail

SNAP="/snap/podman-m0x41/current"
SNAP_FILE="/root/podman-m0x41_5.8.1_amd64.snap"
TESTUSER="podtest"
PODMAN_SRC="/opt/podman"

echo "=== Phase 1: Install prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    uidmap \
    dbus-user-session \
    2>&1 | tail -5

echo "=== Phase 2: Install snap (classic) ==="
snap wait system seed.loaded 2>/dev/null || true
snap install "${SNAP_FILE}" --dangerous --classic
echo "Installed: $(podman-m0x41 --version)"

echo "=== Phase 3: Create test user ==="
if ! id "${TESTUSER}" &>/dev/null; then
    useradd -m -s /bin/bash "${TESTUSER}"
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${TESTUSER}"
    loginctl enable-linger "${TESTUSER}" 2>/dev/null || true
fi

TESTUSER_UID=$(id -u "${TESTUSER}")

echo "=== Phase 4: Configure libraries and policy ==="
# Register snap's bundled libraries (libyajl, libslirp) with the system
# linker. The wrapper sets LD_LIBRARY_PATH for podman itself, but child
# processes (conmon → crun) don't inherit it.
echo "${SNAP}/usr/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/podman-snap.conf
ldconfig

# Classic confinement sees the host filesystem, so place policy.json
# at the standard system location.
mkdir -p /etc/containers
cp "${SNAP}/etc/containers/policy.json" /etc/containers/policy.json

echo "=== Phase 5: Install tier4 dependencies (Go, BATS, Podman source) ==="
# Go
if [ ! -d /usr/local/go ]; then
    echo "Installing Go 1.24.2..."
    curl -fsSL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH
echo "Go: $(go version)"

# BATS
if ! command -v bats &>/dev/null; then
    echo "Installing BATS..."
    apt-get install -y -qq git 2>&1 | tail -3
    git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
    /tmp/bats-core/install.sh /usr/local
    rm -rf /tmp/bats-core
fi
echo "BATS: $(bats --version)"

# Podman source (for BATS test files)
if [ ! -d "${PODMAN_SRC}" ]; then
    echo "Cloning Podman v5.8.1 source..."
    git clone --depth 1 --branch v5.8.1 https://github.com/containers/podman.git "${PODMAN_SRC}"
fi

# Dependencies needed by BATS helpers (skopeo for image prefetch, jq, socat, openssl).
# skopeo pulls golang-github-containers-common which ships policy.json —
# --force-confold keeps our copy.
apt-get install -y -qq \
    -o Dpkg::Options::="--force-confold" \
    skopeo \
    jq \
    socat \
    openssl \
    2>&1 | tail -3

# Disable AppArmor userns restriction if present (not expected on 22.04,
# but guarded so harmless if the kernel gains it in a point release)
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns
fi

# Fix OpenSSL 3.0.x compatibility (Ubuntu 22.04 lacks -quiet flag, added in 3.2)
if grep -q '^\s*-quiet' "${PODMAN_SRC}/test/system/helpers.bash" 2>/dev/null; then
    sed -i 's/^\(\s*\)-quiet/\1-batch/' "${PODMAN_SRC}/test/system/helpers.bash"
fi

echo ""
echo "=== Setup complete ==="
echo "  Snap: $(podman-m0x41 --version)"
echo "  Test user: ${TESTUSER} (uid ${TESTUSER_UID})"
echo "  Subuids: $(grep "^${TESTUSER}:" /etc/subuid)"
echo "  Go: $(go version)"
echo "  BATS: $(bats --version)"
echo "  Podman source: ${PODMAN_SRC}"
