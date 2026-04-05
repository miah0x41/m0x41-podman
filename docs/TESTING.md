# Testing

This document covers the test methodology and how to run tests. For recorded results, see [TESTING-RESULTS.md](TESTING-RESULTS.md).

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
