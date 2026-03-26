# Testing

This document covers the test methodology, how to run tests, and recorded results.

## Test Tiers

The snap is validated with a five-tier test suite. Each tier builds on the confidence established by the previous one.

| Tier | Name | Tests | What It Validates |
|------|------|-------|-------------------|
| 1 | Snap Command Validation | 7 | The snap binary runs, reports correct versions, and finds all bundled components (`crun`, `netavark`, `conmon`, overlay driver, config paths) |
| 2 | Rootless Functional | 8 | Pull, run, build, pod lifecycle, volume lifecycle, DNS resolution, user namespace mapping — all as an unprivileged user |
| 3 | Rootful Functional | 6 | Run, build, pod lifecycle, volume lifecycle — as root |
| 4 | BATS Parity | 31 | Upstream _Podman_ `00*.bats` smoke tests from the v5.8.1 source tree, with `PODMAN` pointed at the snap binary |
| 5 | Quadlet / Install Hook | 18+ | Install hook artefacts (including socket units), Quadlet dry-run, live rootful and rootless Quadlet services, upstream BATS system-service, socket-activation, and quadlet tests (gated), Go e2e quadlet tests (gated) |

All tests in tiers 1-3 run through `snap run m0x41-podman` — the snap's actual entry point, not a bypass of the binary. Tier 5 tests the `/usr/local/bin/podman` shim created by the install hook.

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

Launches LXD containers for five distros in parallel, installs the snap on each, and runs tiers 1-3 and 5.

```bash
# Run all distros
/usr/bin/sg lxd -c "./scripts/06_test_multi_distro.sh"

# Run with cleanup (delete containers after)
/usr/bin/sg lxd -c "./scripts/06_test_multi_distro.sh --cleanup"
```

### Re-Running Tests on an Existing Container

```bash
# Single-distro test container
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test -- /root/05_run_tests.sh tier2"

# Multi-distro container
/usr/bin/sg lxd -c "lxc exec snap-test-22-debian-12 -- /root/05_run_tests.sh tier1"
```

### Wrapper Dependency Tests

Validates the wrapper's first-run hello message, dependency detection, marker file logic, and alias tip across five distros. These tests use a minimal container setup that deliberately omits rootless dependencies.

```bash
# All distros in parallel
/usr/bin/sg lxd -c "./scripts/08_wrapper_test_launch.sh"

# With cleanup
/usr/bin/sg lxd -c "./scripts/08_wrapper_test_launch.sh --cleanup"

# Re-run on existing container
/usr/bin/sg lxd -c "lxc exec snap-wtest-22-debian-12 -- /root/10_wrapper_tests.sh"
```

See [WRAPPER.md](WRAPPER.md) for full details on test phases and what each test validates.

### Interactive Debugging

```bash
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test -- bash"
/usr/bin/sg lxd -c "lxc exec snap-test-22-centos-9 -- bash"
/usr/bin/sg lxd -c "lxc exec snap-wtest-22-debian-12 -- bash"
```

## Test Results

### `core22` Snap — Single Distro (Ubuntu 24.04)

Tested 2026-03-25 on WSL2.

| Tier | LXC Container | Description |
|------|--------------|-------------|
| 1 | 7/7 pass | Version, `crun`, `netavark`, overlay, `conmon`, config paths |
| 2 | 8/8 pass | Rootless: pull, run, build, pod, volume, unshare, DNS |
| 3 | 6/6 pass | Rootful: run, build, pod, volume |
| 4 | 28/31 | `BATS` parity — 3 snap-specific failures (see [Known Failures](#known-failures)) |
| 5a-5d | 18/18 pass | Install hook (including socket units), Quadlet dry-run, live rootful/rootless Quadlet |
| 5e | 68/73 | `BATS` system-service (19/19), socket-activation (3/3), quadlet 252-254 — 5 failures in `252-quadlet.bats` |

### `core22` Snap — Multi-Distro

Tested 2026-03-25 on WSL2. All distros run in parallel via `06_test_multi_distro.sh`.

| Distro | `glibc` | Tier 1 (7) | Tier 2 (8) | Tier 3 (6) | Tier 5 (18) |
|--------|---------|------------|------------|------------|-------------|
| Ubuntu 22.04 | 2.35 | 7/7 | 8/8 | 6/6 | 18/18 |
| Ubuntu 24.04 | 2.39 | 7/7 | 8/8 | 6/6 | 18/18 |
| Debian 12 | 2.36 | 7/7 | 8/8 | 6/6 | 18/18 |
| CentOS 9 | 2.34 | 7/7 | 8/8 | 6/6 | 17/18 |
| Fedora 42 | 2.41 | 5/7 | 1/8 | 6/6 | 16/18 |

### Native Build (Ubuntu 24.04, VM)

The baseline — all tiers pass against _Podman_ built and installed natively (no snap packaging).

| Tier | Result | Description |
|------|--------|-------------|
| 1 | 3/3 pass | Build validation |
| 2 | 54/54 pass | Unit tests (`Ginkgo` suites) |
| 3 | 7/7 pass | Rootless functional + `BATS` smoke (31 tests) |
| 4 | 352/352 pass | Root `BATS` smoke (31) + `Ginkgo` integration (321 specs) |
| 5 | 544/548 | API v2 tests (4 upstream failures in OCI artifact tests) |

### Wrapper Dependency Detection — Multi-Distro

Tested 2026-03-24 on WSL2. All distros run in parallel via `08_wrapper_test_launch.sh`.

| Distro | Wrapper Tests (18) |
|--------|--------------------|
| Ubuntu 22.04 | **18/18 pass** |
| Ubuntu 24.04 | **18/18 pass** |
| Debian 12 | **18/18 pass** |
| CentOS 9 Stream | **18/18 pass** |
| Fedora 42 | **18/18 pass** |

## Known Failures

### Tier 4: 3 `BATS` Failures (Snap Config Conflicts)

| Test | Cause |
|------|-------|
| `podman info - json` | Snap's `CONTAINERS_CONF` env var overrides the test's temporary config; teardown cleans up state that was never created |
| `CONTAINERS_CONF_OVERRIDE` | Test sets `CONTAINERS_CONF` — but the snap's env var (from `snapcraft.yaml`) takes precedence |
| `empty string defaults` | Test expects a warning when no storage driver is configured; the snap always provides `CONTAINERS_STORAGE_CONF` |

All three are snap-specific environment conflicts, not functional regressions. The same tests pass in the native build.

### Tier 5e: 5 `252-quadlet.bats` Failures

Five tests in `252-quadlet.bats` fail: `basic`, `envvar`, `userns`, `image files`, and `artifact`. The `artifact` test fails because `htpasswd` (`apache2-utils`) is not installed in the test container. The others are snap-specific environment conflicts similar to the tier 4 failures. Tests `253-podman-quadlet.bats` (9/9) and `254-podman-quadlet-multi.bats` (5/5) pass fully.

### Fedora 42: Rootless Failures in LXD

`newuidmap` lacks the setuid bit inside LXD containers on Fedora. All rootless operations fail with `Operation not permitted`. This is an LXD/Fedora environment limitation — on a real Fedora host with setuid `newuidmap`, rootless would work. Rootful (tier 3) passes all 6 tests.

### Rootless Requires Host `uidmap` and `dbus-user-session`

The snap does not bundle `uidmap` (`newuidmap`/`newgidmap`) or `dbus-user-session` — these must exist on the host and are accessed through classic confinement. `uidmap` provides the setuid binaries for user namespace creation; `dbus-user-session` provides the D-Bus user session bus needed by `loginctl enable-linger` and rootless Podman for `XDG_RUNTIME_DIR`. Ubuntu Desktop installs both by default, but server, minimal, and container images do not. Without them, rootless operations fail. Install with `sudo apt install uidmap dbus-user-session` (Debian/Ubuntu) or `sudo dnf install shadow-utils` (Fedora/CentOS).

### Fedora/CentOS Requires Host `libgpg-error`

The snap bundles `libgpgme` but not its dependency `libgpg-error`. On Fedora and CentOS this must be installed on the host: `sudo dnf install libgpg-error`. On Debian/Ubuntu it is typically already present.

### Non-Ubuntu Distros: Rootful Requires Host `iptables`

`netavark` calls `iptables` as a child process of `conmon`, which does not inherit the snap wrapper's `PATH`. Ubuntu ships `iptables` by default; Debian 12, CentOS 9, and Fedora 42 use `nftables` and require a compatibility package:

| Distro | Package |
|--------|---------|
| Debian 12 | `apt install iptables` |
| CentOS 9 / Fedora 42 | `dnf install iptables-nft` |

Setting `firewall_driver = "nftables"` in `containers.conf` was attempted but fails in LXD on WSL2 due to missing kernel `nftables` modules. On hosts with full `nftables` support, this may work.

## Full Upstream BATS Suite

In addition to the tiered regression tests above, the snap can be validated against the complete upstream _Podman_ BATS test suite (78 files, ~780 tests). This provides a transparent view of compatibility — not all tests are expected to pass, and the results are categorised to explain why.

### Running the Full Suite

```bash
# Root mode (inside the test container, after 04_test_setup.sh)
/root/11_run_bats_full.sh root

# Rootless mode
/root/11_run_bats_full.sh rootless
```

The script runs every `*.bats` file in the upstream `test/system/` directory, groups results by functional category, and classifies failures into four buckets:

| Classification | Meaning |
|---------------|---------|
| **Snap** | Snap-specific environment conflict (`CONTAINERS_CONF` override, path issues) |
| **LXD** | LXD container limitation (`newuidmap` setuid, namespace permissions) |
| **Infra** | Missing test infrastructure (registry, `htpasswd`, `skopeo`, test binary) |
| **Other** | Requires manual investigation |

### Results — Root Mode (Ubuntu 24.04, LXC)

Tested 2026-03-25 on WSL2.

| Category | Tests | Pass | Skip | Snap | LXD | Infra | Other |
|----------|-------|------|------|------|-----|-------|-------|
| System & Info | 116 | 83 | 12 | 6 | 0 | 0 | 15 |
| Container Lifecycle | 149 | 130 | 11 | 5 | 0 | 0 | 3 |
| Images | 101 | 76 | 2 | 3 | 0 | 18 | 2 |
| Volumes & Storage | 59 | 52 | 4 | 0 | 0 | 0 | 3 |
| Networking | 111 | 20 | 89 | 2 | 0 | 0 | 0 |
| Pods & Kube | 59 | 53 | 2 | 0 | 0 | 2 | 2 |
| Systemd & Quadlet | 113 | 40 | 12 | 15 | 0 | 0 | 46 |
| Security & Namespaces | 47 | 18 | 25 | 0 | 3 | 0 | 1 |
| Advanced | 27 | 8 | 19 | 0 | 0 | 0 | 0 |
| **Total** | **782** | **480** | **176** | **31** | **3** | **20** | **72** |

**480/782 tests pass (61%).** 176 tests are skipped (SELinux not available, `pasta` not bundled, checkpoint/restore not supported, remote-only tests). Of the 126 failures:

- **31 snap-specific** — environment variable conflicts where the snap's `CONTAINERS_CONF`/`CONTAINERS_STORAGE_CONF` override the test harness's temporary configs. Not functional regressions.
- **3 LXD** — user namespace tests that require setuid `newuidmap`, which lacks the setuid bit in LXD containers.
- **20 infra** — tests requiring a container registry (`htpasswd`), `skopeo --preserve-digests`, or the `podman_testing` binary, none of which are available in the test container.
- **72 other** — includes 46 Systemd & Quadlet tests that fail due to cascading `setup_suite` failures (effectively infra), plus tests requiring manual investigation.

### Notes

- **Networking skips (89)** are almost entirely `505-networking-pasta.bats` — the snap uses `slirp4netns`, not `pasta`.
- **Security skips (25)** include 21 SELinux tests — SELinux is not enabled in Ubuntu LXD containers.
- **Advanced skips (19)** include checkpoint/restore, migration, SSH, and remote tests.
- The "Other" count is inflated by cascading `setup_suite` failures in `252-quadlet.bats` and `253-podman-quadlet.bats`, which should be reclassified as infra. The failure classifier is heuristic and will be refined.

## Test Environment

All tests were run on:

- **Host**: WSL2 (Linux 6.6.87.2-microsoft-standard-WSL2)
- **LXD**: 5.21.4 LTS (snap)
- **LXC containers**: `security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true`
- **LXD VMs**: `security.secureboot=false`, no nesting or syscall flags needed
