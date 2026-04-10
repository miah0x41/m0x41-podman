# Test Results

Recorded results from the test tiers described in [TESTING.md](TESTING.md).

## `core22` Snap — Single Distro (Ubuntu 24.04)

| Tier | LXC Container | LXD VM | Description |
|------|--------------|--------|-------------|
| 1 | 7/7 pass | 7/7 pass | Version, `crun`, `netavark`, overlay, `conmon`, config paths |
| 2 | 8/8 pass | 8/8 pass | Rootless: pull, run, build, pod, volume, unshare, DNS |
| 3 | 6/6 pass | 6/6 pass | Rootful: run, build, pod, volume |
| 4 | 29/31 | 29/31 | `BATS` parity — 2 snap-specific failures (see [Known Failures](#known-failures)) |
| 5a-5d,5g | 48/48 pass | 48/48 pass | Install hook, Quadlet dry-run, live rootful/rootless Quadlet, healthcheck transient unit validation |
| 5e | 68/73 | 71/73 | `BATS` system-service, socket-activation, quadlet 252-254 |
| 6 | — | 31/31 pass | Host-side impact: network, ldconfig, systemd, reboot, removal |

## `core22` Snap — Multi-Distro

All distros run in parallel via `06_test_multi_distro.sh`.

| Distro | `glibc` | Tier 1 (7) | Tier 2 (8) | Tier 3 (6) | Tier 5 (48) |
|--------|---------|------------|------------|------------|-------------|
| Ubuntu 22.04 | 2.35 | 7/7 | 8/8 | 6/6 | 48/48 |
| Ubuntu 24.04 | 2.39 | 7/7 | 8/8 | 6/6 | 48/48 |
| Debian 12 | 2.36 | 7/7 | 8/8 | 6/6 | 48/48 |
| CentOS 9 | 2.34 | 7/7 | 8/8 | 6/6 | 48/48 |
| Fedora 43 | 2.41 | 5/7 | 1/8 | 6/6 | 38/48 |

Fedora 43 rootless failures are caused by `newuidmap` lacking the setuid bit inside LXD containers (see [Known Failures](#fedora-rootless-failures-in-lxd)). Rootful (tier 3) passes all 6 tests.

## Native Build (Ubuntu 24.04, VM)

The baseline — all tiers pass against _Podman_ built and installed natively (no snap packaging).

| Tier | Result | Description |
|------|--------|-------------|
| 1 | 3/3 pass | Build validation |
| 2 | 54/54 pass | Unit tests (`Ginkgo` suites) |
| 3 | 7/7 pass | Rootless functional + `BATS` smoke (31 tests) |
| 4 | 352/352 pass | Root `BATS` smoke (31) + `Ginkgo` integration (321 specs) |
| 5 | 544/548 | API v2 tests (4 upstream failures in OCI artifact tests) |

## Wrapper Dependency Detection — Multi-Distro

All distros run in parallel via `08_wrapper_test_launch.sh`.

| Distro | Wrapper Tests (18) |
|--------|--------------------|
| Ubuntu 22.04 | **18/18 pass** |
| Ubuntu 24.04 | **18/18 pass** |
| Debian 12 | **18/18 pass** |
| CentOS 9 Stream | **18/18 pass** |
| Fedora 43 | **18/18 pass** |

## Known Failures

### Tier 4: 2 `BATS` Failures

| Test | Cause |
|------|-------|
| `podman info - json` | `conmon.package` reports `Unknown` (snap builds conmon from source); `rootlessNetworkCmd` is `slirp4netns` (snap bundles `slirp4netns`, not `pasta`) |
| `CONTAINERS_CONF_OVERRIDE` | Test provides a custom `CONTAINERS_CONF` that defaults to `pasta` networking; `pasta` is not bundled in the snap (`core22` base) |

Both are structural snap differences, not functional regressions. The same tests pass in the native build. `empty string defaults` was previously failing but is now recovered by the adapted shim (config env vars are no longer force-set).

### Tier 5e: `252-quadlet.bats` Failures

In LXC: 5 failures — `basic`, `envvar`, `userns`, `image files`, and `artifact`. In the VM: 2 failures — `basic` (times out waiting for `STARTED CONTAINER`) and `envvar` (environment variable passthrough differs under snap shim). The remaining 3 LXC-only failures are resolved by the full VM kernel and `apache2-utils`. Tests `253-podman-quadlet.bats` (9/9), `254-podman-quadlet-multi.bats` (5/5), `251-system-service.bats` (19/19), and `270-socket-activation.bats` (3/3) pass in both environments.

### Fedora: Rootless Failures in LXD

`newuidmap` lacks the setuid bit inside LXD containers on Fedora. All rootless operations fail with `Operation not permitted`. This is an LXD/Fedora environment limitation — on a real Fedora host with setuid `newuidmap`, rootless would work. Rootful (tier 3) passes all 6 tests. Confirmed on both Fedora 42 and 43.

### Rootless Requires Host `uidmap` and `dbus-user-session`

The snap does not bundle `uidmap` (`newuidmap`/`newgidmap`) or `dbus-user-session` — these must exist on the host and are accessed through classic confinement. `uidmap` provides the setuid binaries for user namespace creation; `dbus-user-session` provides the D-Bus user session bus needed by `loginctl enable-linger` and rootless _Podman_ for `XDG_RUNTIME_DIR`. Ubuntu Desktop installs both by default, but server, minimal, and container images do not. Without them, rootless operations fail. Install with `sudo apt install uidmap dbus-user-session` (Debian/Ubuntu) or `sudo dnf install shadow-utils` (Fedora/CentOS).

### Fedora/CentOS Requires Host `libgpg-error`

The snap bundles `libgpgme` but not its dependency `libgpg-error`. On Fedora and CentOS this must be installed on the host: `sudo dnf install libgpg-error`. On Debian/Ubuntu it is typically already present.

### Non-Ubuntu Distros: Rootful Requires Host `iptables`

`netavark` calls `iptables` as a child process of `conmon`, which does not inherit the snap wrapper's `PATH`. Ubuntu ships `iptables` by default; Debian 12, CentOS 9, and Fedora 43 use `nftables` and require a compatibility package:

| Distro | Package |
|--------|---------|
| Debian 12 | `apt install iptables` |
| CentOS 9 / Fedora 43 | `dnf install iptables-nft` |

Setting `firewall_driver = "nftables"` in `containers.conf` was attempted but fails in LXD due to missing kernel `nftables` modules. On hosts with full `nftables` support, this may work.

## Full Upstream BATS Suite

In addition to the tiered regression tests above, the snap can be validated against the complete upstream _Podman_ BATS test suite (78 files, 785 tests). This provides a transparent view of compatibility — not all tests are expected to pass, and the results are categorised to explain why.

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

### Results — Root Mode (Ubuntu 24.04, VM)

| Category | Tests | Pass | Skip | Fail |
|----------|-------|------|------|------|
| System & Info | 116 | 89 | 12 | 15 |
| Container Lifecycle | 149 | 137 | 11 | 1 |
| Images | 104 | 102 | 2 | 0 |
| Volumes & Storage | 59 | 55 | 3 | 1 |
| Networking | 111 | 21 | 89 | 1 |
| Pods & Kube | 59 | 55 | 3 | 1 |
| Systemd & Quadlet | 113 | 96 | 15 | 2 |
| Security & Namespaces | 47 | 21 | 26 | 0 |
| Advanced | 27 | 8 | 19 | 0 |
| **Total** | **785** | **584** | **180** | **21** |

Of the 785 tests, 180 are skipped by the test harness (`pasta` networking, SELinux, checkpoint/restore, SSH/remote — features the snap does not ship). Of the **605 applicable tests**: **584 pass (96.5%)**. The 21 residual failures are structural (missing `pasta`, `podman-testing` infra, timing). See [investigations/RCCA-BATS-FAILURES.md](investigations/RCCA-BATS-FAILURES.md).

The adapted shim (config env vars set conditionally, respecting pre-existing values) recovered **+25 tests** over the previous unconditional config override: System & Info (+6), Container Lifecycle (+1), Images (+3), Systemd & Quadlet (+15).

### Results — Rootless Mode (Ubuntu 24.04, VM)

| Category | Tests | Pass | Skip | Fail |
|----------|-------|------|------|------|
| System & Info | 116 | 89 | 10 | 17 |
| Container Lifecycle | 149 | 142 | 6 | 1 |
| Images | 104 | 101 | 3 | 0 |
| Volumes & Storage | 59 | 52 | 7 | 0 |
| Networking | 111 | 19 | 1 | 91 |
| Pods & Kube | 59 | 56 | 2 | 1 |
| Systemd & Quadlet | 113 | 95 | 13 | 5 |
| Security & Namespaces | 47 | 18 | 29 | 0 |
| Advanced | 27 | 12 | 15 | 0 |
| **Total** | **785** | **584** | **86** | **115** |

**584/785 pass, 86 skipped, 115 failures.** However, 91 of those failures are `pasta` networking tests (`505-networking-pasta.bats` + `500-networking.bats`) that skip in root mode but fail in rootless mode because the snap bundles `slirp4netns` instead of `pasta`. Excluding `pasta`: **584/608 applicable tests (96.1%)** with 24 real failures.

The adapted shim recovered **+73 tests** over the previous unconditional config override (up from 511). Rootless passes the same number of tests as root mode (584) because root-only skips (e.g. `060-mount.bats`, `550-pause-process.bats`) become rootless-passing tests, offsetting the additional `pasta` failures.

### Notes

- **`pasta` networking tests (91 rootless, 89 root skips)** are not applicable. The snap bundles `slirp4netns` because `pasta`/`passt` is not available on the `core22` (Ubuntu 22.04) base. In root mode the test harness detects `pasta` as absent and skips them; in rootless mode it attempts to run them and they fail. These should be excluded when comparing against native _Podman_ pass rates.
- **Adapted shim** — the shim and wrapper now set `CONTAINERS_CONF`, `CONTAINERS_REGISTRIES_CONF`, and `CONTAINERS_STORAGE_CONF` conditionally (`${VAR:-default}`), respecting pre-existing values. This recovered 25 root and 73 rootless tests that previously failed due to config overrides.
- **Remaining snap-specific failures** are structural — `podman generate systemd` (deprecated) embeds the snap's internal binary path, and `podman-testing` runs outside the snap environment. See [investigations/RCCA-ADAPTED-FAILURES.md](investigations/RCCA-ADAPTED-FAILURES.md).
- **`podman-testing` (11 failures)**: The binary builds but cannot find the snap's `conmon` because it runs outside the snap's environment. These are infra-structural.
- **`conmon` upgraded to v2.0.26**: Fixes stderr data loss with large stdout volumes (`030-run.bats` test 34). See [conmon#236](https://github.com/containers/conmon/issues/236). Built from source (pre-built binaries lack journald support).
- **Security skips (26 root, 29 rootless)** include SELinux tests — SELinux is not enabled in Ubuntu.
- **Advanced skips (19 root, 15 rootless)** include checkpoint/restore, SSH, and remote tests.

## `core22` Snap — Host-Side Impact (Tier 6, VM)

These tests can only run in a VM because they validate system-level side effects invisible from inside a nested container.

| Test Group | Tests | Result |
|-----------|-------|--------|
| 6a: Network integrity | 5 | 5/5 pass — DNS, default route, no stale interfaces, no snap iptables paths, resolv.conf clean |
| 6b: Library path integrity | 3 | 3/3 pass — ldconfig cache, ld.so.conf.d, host `ldd` all clean |
| 6c: systemd health | 3 | 3/3 pass — no failed podman units, systemd-resolved active, system running |
| 6d: Reboot survival | 9 | 9/9 pass — snap, shim, podman, rootful, rootless, DNS, ldconfig, units, quadlet all survive reboot |
| 6e: Snap removal cleanup | 11 | 11/11 pass — shim, generators, quadlet, units, man pages, ldconfig, ld.so.conf.d, systemd units, DNS, systemd all clean after removal |
| **Total** | **31** | **31/31 pass** |

## Test Environment

**Bare-metal** (2026-04-01):

- **Host**: Intel i7-8700, 125 GB RAM, Linux 6.8.0-100-generic (Ubuntu)
- **LXD**: 5.21.4 LTS (snap)
- **LXD VMs**: `security.secureboot=false`, no nesting or syscall flags needed
- **Note**: `apparmor_restrict_unprivileged_userns` must be set to `0` for rootless tests on Ubuntu 24.04+. The test setup script (`04_test_setup.sh`) handles this and persists it via sysctl.
