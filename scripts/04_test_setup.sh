#!/bin/bash
# 04_test_setup.sh — Runs INSIDE the LXD container as root
# Installs the snap (classic), prerequisites, creates test user, and
# optionally installs Go/BATS/Podman source for tier4 BATS parity tests.
set -euo pipefail

SNAP="/snap/m0x41-podman/current"
SNAP_FILE="/root/m0x41-podman.snap"
TESTUSER="podtest"
PODMAN_SRC="/opt/podman"

echo "=== Phase 1: Install prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    uidmap \
    dbus-user-session \
    man-db \
    make \
    gcc \
    pkg-config \
    libgpgme-dev \
    libseccomp-dev \
    libbtrfs-dev \
    2>&1 | tail -5

echo "=== Phase 2: Install snap (classic) ==="
snap wait system seed.loaded 2>/dev/null || true
snap install "${SNAP_FILE}" --dangerous --classic
export PATH="/snap/bin:$PATH"
echo "Installed: $(m0x41-podman --version)"

echo "=== Phase 3: Create test user ==="
if ! id "${TESTUSER}" &>/dev/null; then
    useradd -m -s /bin/bash "${TESTUSER}"
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${TESTUSER}"
    loginctl enable-linger "${TESTUSER}" 2>/dev/null || true
fi

TESTUSER_UID=$(id -u "${TESTUSER}")

echo "=== Phase 4: Verify install hook artefacts ==="
# The snap install hook (snap/hooks/install) should have created these
# automatically during snap install. Verify rather than duplicate.
HOOK_OK=true
test -f /usr/local/bin/podman && echo "  Shim: OK" || { echo "  WARNING: /usr/local/bin/podman shim missing"; HOOK_OK=false; }
test -L /usr/lib/systemd/system-generators/podman-system-generator && echo "  System generator: OK" || { echo "  WARNING: system generator symlink missing"; HOOK_OK=false; }
test -L /usr/lib/systemd/user-generators/podman-user-generator && echo "  User generator: OK" || { echo "  WARNING: user generator symlink missing"; HOOK_OK=false; }
test -f /etc/containers/policy.json && echo "  policy.json: OK" || { echo "  WARNING: policy.json missing"; HOOK_OK=false; }
test -x "${SNAP}/bin/conmon-wrapper" && echo "  conmon-wrapper: OK" || { echo "  WARNING: conmon-wrapper missing"; HOOK_OK=false; }
test -x "${SNAP}/bin/crun-wrapper" && echo "  crun-wrapper: OK" || { echo "  WARNING: crun-wrapper missing"; HOOK_OK=false; }
test -L /usr/local/share/man/man1/podman.1 && echo "  Man pages: OK" || echo "  WARNING: man page symlinks missing"
if [ "${HOOK_OK}" = false ]; then
    echo "  Install hook may have failed — falling back to manual setup"
    mkdir -p /etc/containers
    cp "${SNAP}/etc/containers/policy.json" /etc/containers/policy.json
fi

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
    apache2-utils \
    buildah \
    2>&1 | tail -3

# Build podman-testing helper binary (used by 331-system-check.bats)
if [ ! -f "${PODMAN_SRC}/bin/podman-testing" ] && [ -d "${PODMAN_SRC}/cmd/podman-testing" ]; then
    echo "Building podman-testing helper..."
    cd "${PODMAN_SRC}" && make podman-testing 2>&1 | tail -5 || echo "WARNING: podman-testing build failed (331-system-check.bats will skip)"
    cd /root
fi

# Disable AppArmor userns restriction if present (Ubuntu 24.04+).
# Both set it now and persist it so VM reboots retain the setting.
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true
    echo "kernel.apparmor_restrict_unprivileged_userns=0" > /etc/sysctl.d/99-userns.conf 2>/dev/null || true
fi

# Fix OpenSSL 3.0.x compatibility (Ubuntu 22.04 lacks -quiet flag, added in 3.2)
if grep -q '^\s*-quiet' "${PODMAN_SRC}/test/system/helpers.bash" 2>/dev/null; then
    sed -i 's/^\(\s*\)-quiet/\1-batch/' "${PODMAN_SRC}/test/system/helpers.bash"
fi

echo ""
echo "=== Setup complete ==="
echo "  Snap: $(m0x41-podman --version)"
echo "  Test user: ${TESTUSER} (uid ${TESTUSER_UID})"
echo "  Subuids: $(grep "^${TESTUSER}:" /etc/subuid)"
echo "  Go: $(go version)"
echo "  BATS: $(bats --version)"
echo "  Podman source: ${PODMAN_SRC}"
