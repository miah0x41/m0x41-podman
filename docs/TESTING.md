# Testing

This document covers the test methodology, how to run tests, and recorded results.

## Test Tiers

The snap is validated with a seven-tier test suite. Tiers 1-5 form the core regression suite. Tier 6 validates host-side impact (VM only). Tier 7 runs the full upstream BATS suite (on-demand).

| Tier | Name | Tests | What It Validates |
|------|------|-------|-------------------|
| 1 | Snap Command Validation | 7 | The snap binary runs, reports correct versions, and finds all bundled components (`crun`, `netavark`, `conmon`, overlay driver, config paths) |
| 2 | Rootless Functional | 8 | Pull, run, build, pod lifecycle, volume lifecycle, DNS resolution, user namespace mapping — all as an unprivileged user |
| 3 | Rootful Functional | 6 | Run, build, pod lifecycle, volume lifecycle — as root |
| 4 | BATS Parity | 31 | Upstream _Podman_ `00*.bats` smoke tests from the v5.8.1 source tree, with `PODMAN` pointed at the snap binary |
| 5 | Quadlet / Install Hook | 20+ | Install hook artefacts (including socket units, man pages), Quadlet dry-run, live rootful and rootless Quadlet services, upstream BATS system-service, socket-activation, and quadlet tests (gated), Go e2e quadlet tests (gated) |
| 6 | Host-Side Impact (VM) | 25+ | Network integrity, library path poisoning, systemd health, reboot survival, snap removal cleanup — requires full VM |
| 7 | Full Upstream BATS (on-demand) | 785 | All upstream `test/system/*.bats` files in both root and rootless modes, with categorised failure classification |

All tests in tiers 1-3 run through `snap run m0x41-podman` — the snap's actual entry point, not a bypass of the binary. Tier 5 tests the `/usr/local/bin/podman` shim created by the install hook. Tier 6 requires a VM (full kernel isolation) because it validates host-level side effects that cannot be observed in a nested container. Tier 7 is excluded from `all` due to its runtime (~2 hours).

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

### Tier 6: Host-Side Impact (VM Only)

Tier 6 runs automatically as part of `all` when using the VM launcher. It can also be run separately, including the reboot and removal sub-tests:

```bash
# Run tier 6 (host-side impact checks)
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/05_run_tests.sh tier6"

# Reboot the VM, then re-run to validate post-reboot state
/usr/bin/sg lxd -c "lxc restart m0x41-podman-test-vm"
# (wait ~60s for VM to boot)
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/05_run_tests.sh tier6"

# Remove snap and validate cleanup
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- snap remove m0x41-podman"
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/05_run_tests.sh tier6_removal"
```

### Tier 7: Full Upstream BATS (On-Demand)

Runs all 76 upstream BATS test files in both root and rootless modes. Requires `04_test_setup.sh` to have run (Go, BATS, _Podman_ source). This can be run inside either an LXC container or a VM, but VM results are more authoritative because LXD container limitations are eliminated.

```bash
# Via tier7 wrapper (both modes)
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/05_run_tests.sh tier7"

# Or run 11_run_bats_full.sh directly for a single mode
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/11_run_bats_full.sh root"
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test-vm -- /root/11_run_bats_full.sh rootless"
```

### Interactive Debugging

```bash
/usr/bin/sg lxd -c "lxc exec m0x41-podman-test -- bash"
/usr/bin/sg lxd -c "lxc exec snap-test-22-centos-9 -- bash"
/usr/bin/sg lxd -c "lxc exec snap-wtest-22-debian-12 -- bash"
```

## Test Results

### `core22` Snap — Single Distro (Ubuntu 24.04)

Tested 2026-03-25 (LXC, WSL2) and 2026-04-01 (VM, bare-metal).

| Tier | LXC Container | LXD VM | Description |
|------|--------------|--------|-------------|
| 1 | 7/7 pass | 7/7 pass | Version, `crun`, `netavark`, overlay, `conmon`, config paths |
| 2 | 8/8 pass | 8/8 pass | Rootless: pull, run, build, pod, volume, unshare, DNS |
| 3 | 6/6 pass | 6/6 pass | Rootful: run, build, pod, volume |
| 4 | 28/31 | 28/31 | `BATS` parity — 3 snap-specific failures (see [Known Failures](#known-failures)) |
| 5a-5d | 20/20 pass | 20/20 pass | Install hook (including socket units, man pages), Quadlet dry-run, live rootful/rootless Quadlet |
| 5e | 68/73 | 69/73 | `BATS` system-service, socket-activation, quadlet 252-254 — `htpasswd` added for VM |
| 6 | — | 25/25 pass | Host-side impact: network, ldconfig, systemd, reboot, removal |

### `core22` Snap — Multi-Distro

Tested 2026-03-25 on WSL2. All distros run in parallel via `06_test_multi_distro.sh`.

| Distro | `glibc` | Tier 1 (7) | Tier 2 (8) | Tier 3 (6) | Tier 5 (20) |
|--------|---------|------------|------------|------------|-------------|
| Ubuntu 22.04 | 2.35 | 7/7 | 8/8 | 6/6 | 20/20 |
| Ubuntu 24.04 | 2.39 | 7/7 | 8/8 | 6/6 | 20/20 |
| Debian 12 | 2.36 | 7/7 | 8/8 | 6/6 | 20/20 |
| CentOS 9 | 2.34 | 7/7 | 8/8 | 6/6 | 19/20 |
| Fedora 42 | 2.41 | 5/7 | 1/8 | 6/6 | 18/20 |

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

### Tier 5e: `252-quadlet.bats` Failures

In LXC (without `htpasswd`): 5 failures — `basic`, `envvar`, `userns`, `image files`, and `artifact`. In the VM (with `apache2-utils` installed): 4 failures — the `artifact` test passes. The remaining 4 are snap-specific environment conflicts similar to the tier 4 failures. Tests `253-podman-quadlet.bats` (9/9) and `254-podman-quadlet-multi.bats` (5/5) pass fully in both environments.

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

### Results — Root Mode (Ubuntu 24.04, LXC vs VM)

LXC tested 2026-03-25 on WSL2. VM tested 2026-04-01 on bare-metal (KVM).

| Category | Tests | Skip | LXC Pass | LXC Fail | VM Pass | VM Fail | Δ Pass |
|----------|-------|------|----------|----------|---------|---------|--------|
| System & Info | 116 | 12 | 83 | 21 | 80 | 24 | -3 |
| Container Lifecycle | 149 | 11 | 130 | 8 | 131 | 7 | +1 |
| Images | 104 | 2 | 76 | 23 | 98 | 4 | +22 |
| Volumes & Storage | 59 | 3–4 | 52 | 3 | 54 | 2 | +2 |
| Networking | 111 | 89 | 20 | 2 | 21 | 1 | +1 |
| Pods & Kube | 59 | 2–3 | 53 | 4 | 53 | 3 | 0 |
| Systemd & Quadlet | 113 | 12 | 40 | 61 | 40 | 61 | 0 |
| Security & Namespaces | 47 | 25–26 | 18 | 4 | 21 | 0 | +3 |
| Advanced | 27 | 19 | 8 | 0 | 8 | 0 | 0 |
| **Total** | **785** | **176–177** | **480** | **126** | **506** | **102** | **+26** |

**VM: 506/785 pass (64%)** vs LXC: 480/782 pass (61%). The VM gains **+26 passing tests**:

- **LXD limitations eliminated**: 3 LXD-specific failures (user namespace `newuidmap` setuid) drop to 0 in the VM.
- **Infra gaps closed**: `htpasswd` (`apache2-utils`) added to test setup — 9 fewer infra failures (20 → 11). Remaining 11 are `331-system-check.bats` which requires the `podman_testing` binary.
- **Images category**: +22 improvement, primarily from `skopeo` and registry tests that work reliably in a full VM.
- **Security**: +3 from user namespace tests that pass with a full kernel.
- **Systemd & Quadlet**: No change — 46 cascading `setup_suite` failures in `252-quadlet.bats` remain in both environments.

### Results — Rootless Mode (Ubuntu 24.04, VM)

Tested 2026-04-01 on bare-metal (KVM). Rootless full BATS was not previously run in LXC.

| Category | Tests | Pass | Skip | Snap | LXD | Infra | Other |
|----------|-------|------|------|------|-----|-------|-------|
| System & Info | 116 | 82 | 10 | 6 | 0 | 11 | 7 |
| Container Lifecycle | 149 | 136 | 6 | 3 | 0 | 0 | 4 |
| Images | 104 | 97 | 3 | 1 | 0 | 0 | 3 |
| Volumes & Storage | 59 | 52 | 7 | 0 | 0 | 0 | 0 |
| Networking | 111 | 19 | 1 | 91 | 0 | 0 | 0 |
| Pods & Kube | 59 | 54 | 2 | 0 | 0 | 0 | 3 |
| Systemd & Quadlet | 113 | 41 | 10 | 16 | 0 | 0 | 46 |
| Security & Namespaces | 47 | 18 | 29 | 0 | 0 | 0 | 0 |
| Advanced | 27 | 12 | 15 | 0 | 0 | 0 | 0 |
| **Total** | **785** | **511** | **83** | **117** | **0** | **11** | **63** |

**511/785 pass (65%), 83 skipped, 191 failures.** Rootless actually passes **5 more tests** than root mode (511 vs 506), because root-only skips (e.g. `060-mount.bats`, `550-pause-process.bats`) become rootless-passing tests. Key differences from root mode:

- **Networking: 91 snap failures** — `505-networking-pasta.bats` (85 failures) and `500-networking.bats` (6 failures). In root mode, pasta tests are skipped; in rootless mode they fail because `slirp4netns` is used instead of `pasta`. The snap bundles `slirp4netns` because `pasta` is not available on the `core22` base.
- **LXD failures: 0** — confirms that all rootless user namespace operations work correctly in a VM with `apparmor_restrict_unprivileged_userns=0`.

### Notes

- **Networking skips/failures** are driven by `505-networking-pasta.bats` (86 tests). The snap bundles `slirp4netns` for rootless networking because `pasta`/`passt` is not available on the `core22` (Ubuntu 22.04) base. In root mode these skip; in rootless mode they fail.
- **Snap-specific failures (26 root / 117 rootless)** are caused by the snap setting `CONTAINERS_CONF` and `CONTAINERS_STORAGE_CONF` as environment variables, which override the test harness's temporary configs. The rootless count is inflated by the 85 pasta failures being classified as snap-specific. Excluding pasta, rootless has 32 snap failures — comparable to root mode's 26.
- **Security skips (26/29)** include 21 SELinux tests — SELinux is not enabled in Ubuntu.
- **Advanced skips (19/15)** include checkpoint/restore, SSH, and remote tests.
- The **"Other" count (65/63)** is inflated by cascading `setup_suite` failures in `252-quadlet.bats` and `253-podman-quadlet.bats` (46 tests), which are effectively infra failures. The failure classifier is heuristic.

### `core22` Snap — Host-Side Impact (Tier 6, VM)

Tested 2026-04-01 on bare-metal (KVM). These tests can only run in a VM because they validate system-level side effects invisible from inside a nested container.

| Test Group | Tests | Result |
|-----------|-------|--------|
| 6a: Network integrity | 5 | 5/5 pass — DNS, default route, no stale interfaces, no snap iptables paths, resolv.conf clean |
| 6b: Library path integrity | 3 | 3/3 pass — ldconfig cache, ld.so.conf.d, host `ldd` all clean |
| 6c: systemd health | 3 | 3/3 pass — no failed podman units, systemd-resolved active, system running |
| 6d: Reboot survival | 9 | 9/9 pass — snap, shim, podman, rootful, rootless, DNS, ldconfig, units, quadlet all survive reboot |
| 6e: Snap removal cleanup | 9 | 9/9 pass — shim, generators, units, man pages, ldconfig, ld.so.conf.d, systemd all clean after removal |
| **Total** | **29** | **29/29 pass** |

## Test Environment

Tests have been run on two hosts:

**WSL2** (LXC container tests, 2026-03-25):

- **Host**: WSL2 (Linux 6.6.87.2-microsoft-standard-WSL2)
- **LXD**: 5.21.4 LTS (snap)
- **LXC containers**: `security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true`

**Bare-metal** (VM tests, 2026-04-01):

- **Host**: Intel i7-8700, 125 GB RAM, Linux 6.8.0-100-generic (Ubuntu)
- **LXD**: 5.21.4 LTS (snap)
- **LXD VMs**: `security.secureboot=false`, no nesting or syscall flags needed
- **Note**: `apparmor_restrict_unprivileged_userns` must be set to `0` for rootless tests on Ubuntu 24.04+. The test setup script (`04_test_setup.sh`) handles this and persists it via sysctl.
