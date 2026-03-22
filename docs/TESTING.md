# Testing

This document covers the test methodology, how to run tests, and recorded results.

## Test Tiers

The snap is validated with a four-tier test suite. Each tier builds on the confidence established by the previous one.

| Tier | Name | Tests | What It Validates |
|------|------|-------|-------------------|
| 1 | Snap Command Validation | 7 | The snap binary runs, reports correct versions, and finds all bundled components (`crun`, `netavark`, `conmon`, overlay driver, config paths) |
| 2 | Rootless Functional | 8 | Pull, run, build, pod lifecycle, volume lifecycle, DNS resolution, user namespace mapping — all as an unprivileged user |
| 3 | Rootful Functional | 6 | Run, build, pod lifecycle, volume lifecycle — as root |
| 4 | BATS Parity | 31 | Upstream _Podman_ `00*.bats` smoke tests from the v5.8.1 source tree, with `PODMAN` pointed at the snap binary |

All tests in tiers 1-3 run through `snap run podman-m0x41` — the snap's actual entry point, not a bypass of the binary.

## Running Tests

### Prerequisites

- LXD 5.x (snap) with an initialised storage pool and network bridge
- User in the `lxd` group (no sudo required)
- Internet access (Ubuntu images, container images for functional tests)
- KVM support (`/dev/kvm`) for VM tests

### Single-Distro Test (LXC Container)

Creates a fresh Ubuntu 24.04 LXD container, installs the snap, sets up a test user, and runs the specified tiers.

```bash
# Run all tiers
/usr/bin/sg lxd -c "./scripts/03_test_launch.sh all"

# Run a specific tier
/usr/bin/sg lxd -c "./scripts/03_test_launch.sh tier1"
```

### Single-Distro Test (LXD VM)

LXD VMs provide full kernel isolation — no shared kernel, no nesting flags. Closer to bare-metal. Requires KVM on the host.

```bash
/usr/bin/sg lxd -c "./scripts/03_test_launch_vm.sh all"
```

### Multi-Distro Test

Launches LXD containers for five distros in parallel, installs the snap on each, and runs tiers 1-3.

```bash
# Run all distros
/usr/bin/sg lxd -c "./scripts/06_test_multi_distro.sh"

# Run with cleanup (delete containers after)
/usr/bin/sg lxd -c "./scripts/06_test_multi_distro.sh --cleanup"
```

### Re-Running Tests on an Existing Container

```bash
# Single-distro test container
/usr/bin/sg lxd -c "lxc exec podman-m0x41-test -- /root/05_run_tests.sh tier2"

# Multi-distro container
/usr/bin/sg lxd -c "lxc exec snap-test-22-debian-12 -- /root/05_run_tests.sh tier1"
```

### Interactive Debugging

```bash
/usr/bin/sg lxd -c "lxc exec podman-m0x41-test -- bash"
/usr/bin/sg lxd -c "lxc exec snap-test-22-centos-9 -- bash"
```

## Test Results

### `core22` Snap — Single Distro (Ubuntu 24.04)

Tested 2026-03-19 on WSL2.

| Tier | LXC Container | Description |
|------|--------------|-------------|
| 1 | 7/7 pass | Version, `crun`, `netavark`, overlay, `conmon`, config paths |
| 2 | 8/8 pass | Rootless: pull, run, build, pod, volume, unshare, DNS |
| 3 | 6/6 pass | Rootful: run, build, pod, volume |
| 4 | 0/31 (setup) | `BATS` `setup_suite` fails — Ubuntu 22.04's `skopeo` lacks `--preserve-digests` |

Tier 4 failure is a test infrastructure issue: the upstream `BATS` harness requires a newer `skopeo` to prefetch test images. It does not indicate a functional regression.

### `core22` Snap — Multi-Distro

Tested 2026-03-19 on WSL2. All distros run in parallel via `06_test_multi_distro.sh`.

| Distro | `glibc` | Tier 1 (7) | Tier 2 (8) | Tier 3 (6) | Total |
|--------|---------|------------|------------|------------|-------|
| Ubuntu 22.04 | 2.35 | 7/7 | 8/8 | 6/6 | **21/21** |
| Ubuntu 24.04 | 2.39 | 7/7 | 8/8 | 6/6 | **21/21** |
| Debian 12 | 2.36 | 7/7 | 8/8 | 6/6 | **21/21** |
| CentOS 9 | 2.34 | 7/7 | 8/8 | 6/6 | **21/21** |
| Fedora 42 | 2.41 | 5/7 | 1/8 | 6/6 | 12/21 |

### `core24` Snap — Single Distro (Ubuntu 24.04)

Tested 2026-03-19 on WSL2. Results identical in LXC container and LXD VM.

| Tier | Result | Description |
|------|--------|-------------|
| 1 | 7/7 pass | Version, `crun`, `netavark`, overlay, `conmon` |
| 2 | 8/8 pass | Rootless: run, build, pod, volume, unshare, DNS |
| 3 | 6/6 pass | Rootful: run, build, pod, volume |
| 4 | 28/31 | `BATS` parity — 3 snap-specific failures |

### Native Build (Ubuntu 24.04, VM)

The baseline — all tiers pass against _Podman_ built and installed natively (no snap packaging).

| Tier | Result | Description |
|------|--------|-------------|
| 1 | 3/3 pass | Build validation |
| 2 | 54/54 pass | Unit tests (`Ginkgo` suites) |
| 3 | 7/7 pass | Rootless functional + `BATS` smoke (31 tests) |
| 4 | 352/352 pass | Root `BATS` smoke (31) + `Ginkgo` integration (321 specs) |
| 5 | 544/548 | API v2 tests (4 upstream failures in OCI artifact tests) |

## Known Failures

### `core22` Tier 4: `BATS` `setup_suite` Abort (`skopeo` Too Old)

Ubuntu 22.04's `skopeo` (v1.4.1) lacks the `--preserve-digests` flag used by the _Podman_ v5.8.1 `BATS` `setup_suite` to prefetch test images. All 31 tests are skipped because setup aborts. A newer `skopeo` would resolve this.

### `core24` Tier 4: 3 `BATS` Failures (Snap Config Conflicts)

| Test | Cause |
|------|-------|
| `podman info - json` | Snap's `CONTAINERS_CONF` env var overrides the test's temporary config; teardown cleans up state that was never created |
| `CONTAINERS_CONF_OVERRIDE` | Test sets `CONTAINERS_CONF` — but the snap's env var (from `snapcraft.yaml`) takes precedence |
| `empty string defaults` | Test expects a warning when no storage driver is configured; the snap always provides `CONTAINERS_STORAGE_CONF` |

All three are snap-specific environment conflicts, not functional regressions. The same tests pass in the native build.

### Fedora 42: Rootless Failures in LXD

`newuidmap` lacks the setuid bit inside LXD containers on Fedora. All rootless operations fail with `Operation not permitted`. This is an LXD/Fedora environment limitation — on a real Fedora host with setuid `newuidmap`, rootless would work. Rootful (tier 3) passes all 6 tests.

### Non-Ubuntu Distros: Rootful Requires Host `iptables`

`netavark` calls `iptables` as a child process of `conmon`, which does not inherit the snap wrapper's `PATH`. Ubuntu ships `iptables` by default; Debian 12, CentOS 9, and Fedora 42 use `nftables` and require a compatibility package:

| Distro | Package |
|--------|---------|
| Debian 12 | `apt install iptables` |
| CentOS 9 / Fedora 42 | `dnf install iptables-nft` |

Setting `firewall_driver = "nftables"` in `containers.conf` was attempted but fails in LXD on WSL2 due to missing kernel `nftables` modules. On hosts with full `nftables` support, this may work.

## Test Environment

All tests were run on:

- **Host**: WSL2 (Linux 6.6.87.2-microsoft-standard-WSL2)
- **LXD**: 5.21.4 LTS (snap)
- **LXC containers**: `security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true`
- **LXD VMs**: `security.secureboot=false`, no nesting or syscall flags needed
