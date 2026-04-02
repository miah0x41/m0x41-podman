# Development

This document covers how to build the snap, the build environment requirements, what each script does, and key compatibility issues encountered during development.

## Prerequisites

- **LXD 5.x** (snap) with an initialised storage pool and network bridge
- **User in the `lxd` group** — all LXD commands are run via `/usr/bin/sg lxd -c` (no sudo required)
- **Internet access** — for pulling LXD images, `Go`, _Podman_ source, and container images during testing
- **KVM support** (`/dev/kvm`) — only required for LXD VM tests

The build and all tests run inside LXD containers. Nothing is installed on the host.

## Building the Snap

```bash
/usr/bin/sg lxd -c "./scripts/01_launch.sh"
```

This takes approximately 15-20 minutes. The output is a `.snap` file in the project root.

### What Happens During the Build

1. An Ubuntu 22.04 LXD container is created
2. The `snapcraft` project files (`snapcraft.yaml`, `snap/`, `scripts/podman-wrapper`) are pushed into the container
3. `snapcraft 7.x --destructive-mode` runs inside the container, which:
   - Downloads and stages `Go` 1.24.2 (build-time only, excluded from the snap)
   - Clones and builds `crun` 1.19.1 from source
   - Downloads pre-built `netavark` v1.14.1 and `aardvark-dns` v1.14.0 binaries
   - Clones _Podman_ v5.8.1 from source, applies the healthcheck patch, and builds
   - Stages Ubuntu 22.04 packages: `conmon`, `catatonit`, `fuse-overlayfs`, `slirp4netns`, `iptables`
   - Bundles configuration files and the wrapper script
4. The `.snap` file is pulled back to the host

### `snapcraft.yaml` Overview

The snap definition (`snapcraft.yaml` at the repository root) uses `core22` as the base and classic confinement. It has six parts:

| Part | Plugin | What It Does |
|------|--------|-------------|
| `go` | nil | Downloads `Go` 1.24.2. Excluded from the final snap (`prime: [-*]`) — build-time only |
| `crun` | nil | Clones `crun` 1.19.1, runs `./autogen.sh && ./configure && make && make install` |
| `netavark` | nil | Downloads pre-built `netavark` and `aardvark-dns` binaries from GitHub Releases |
| `podman` | nil | Clones _Podman_ v5.8.1, applies `patches/healthcheck-ld-library-path.patch`, builds `podman`, `podman-remote`, `rootlessport`, `quadlet`, and man pages |
| `configs` | dump | Copies `containers.conf`, `storage.conf`, `registries.conf`, `policy.json` into the snap |
| `wrapper` | dump | Copies wrapper scripts (`podman-wrapper`, `conmon-wrapper`, `crun-wrapper`) that set `PATH` and `LD_LIBRARY_PATH` |

### The Wrapper Script

The snap entry point is `bin/podman-wrapper`, not the _Podman_ binary directly. The wrapper:

1. Prepends the snap's binary directories to `PATH` so _Podman_ can find `netavark`, `aardvark-dns`, `conmon`, etc.
2. Sets `LD_LIBRARY_PATH` so _Podman_ can find bundled shared libraries (`libgpgme`, `libyajl`, etc.)
3. Detects missing host dependencies for rootless mode and prints actionable guidance
4. Shows a one-time welcome message with alias instructions on first run
5. Execs the real `podman` binary

Child processes spawned by `conmon` (e.g. `crun`) don't inherit `LD_LIBRARY_PATH`, which is why `containers.conf` points at `conmon-wrapper` and `crun-wrapper` scripts that restore `LD_LIBRARY_PATH` before exec'ing the real binaries.

See [WRAPPER.md](WRAPPER.md) for full details on the wrapper's messages, marker files, and dependency detection logic.

### Configuration Files

The `snap/` directory contains four configuration files bundled into the snap at `/etc/containers/`:

| File | Purpose |
|------|---------|
| `containers.conf` | Points `helper_binaries_dir`, `conmon_path`, and `crun` runtime at snap paths. Sets `slirp4netns` as the default rootless network backend (`passt` is not available on Ubuntu 22.04) |
| `storage.conf` | Configures overlay storage driver with `fuse-overlayfs` |
| `registries.conf` | Configures docker.io and quay.io as unqualified search registries |
| `policy.json` | Permissive image signature policy (accept all) |

## Script Reference

All scripts are in the `scripts/` directory.

| Script | Runs On | Purpose |
|--------|---------|---------|
| `01_launch.sh` | Host | Creates an Ubuntu 22.04 LXD container, pushes the `snapcraft` project, triggers the build, and pulls the `.snap` file back |
| `02_build_snap.sh` | Build container | Installs `snapcraft` 7.x/stable and runs `snapcraft --destructive-mode` |
| `03_test_launch.sh` | Host | Creates an Ubuntu 24.04 test container, pushes the snap + test scripts, runs setup and tests |
| `03_test_launch_vm.sh` | Host | Same as above but launches an LXD VM instead of a container |
| `04_test_setup.sh` | Test container | Installs the snap, verifies install hook artefacts, creates a test user, installs `Go`/`BATS`/_Podman_ source for tiers 4-5 |
| `05_run_tests.sh` | Test container | Five-tier test runner. Accepts `tier1`..`tier5` or `all` |
| `06_test_multi_distro.sh` | Host | Launches five distro containers in parallel, pushes the snap to each, runs tiers 1-3 and 5 on all, prints a summary table |
| `07_test_setup_multi.sh` | Test container | Distro-agnostic setup — detects the distro, installs `snapd` and prerequisites, installs the snap, creates the test user. Handles Ubuntu, Debian, Fedora, and CentOS/RHEL |
| `08_wrapper_test_launch.sh` | Host | Launches five distro containers in parallel, runs wrapper dependency detection tests on each |
| `09_wrapper_test_setup.sh` | Test container | Minimal setup — installs snap without rootless dependencies to create a "missing deps" scenario |
| `10_wrapper_tests.sh` | Test container | 18-test suite validating wrapper hello message, dependency warnings, marker files, and alias detection |
| `11_run_bats_full.sh` | Test container | Runs the full upstream BATS suite (78 files, ~780 tests) with categorised failure classification. Accepts `root` or `rootless` |
| `podman-wrapper` | Inside snap | Entry point script — sets `PATH`/`LD_LIBRARY_PATH`, detects missing deps, shows first-run guidance, then exec's _Podman_. See [WRAPPER.md](WRAPPER.md) |
| `snap/hooks/install` | Host (on snap install) | Creates `/usr/local/bin/podman` shim, symlinks systemd generators, installs corrected systemd units, symlinks man pages, installs `policy.json`, detects stale native podman artefacts. See [QUADLET.md](QUADLET.md) |
| `snap/hooks/remove` | Host (on snap remove) | Removes shim, generator symlinks, systemd units, and man page symlinks; warns about active Quadlet services |

## Key Compatibility Issues

These are non-obvious problems discovered during development. They are handled in the build and test scripts but documented here for anyone modifying the project.

### `crun` Version Floor

Ubuntu 22.04 ships `crun` 1.8.x; Ubuntu 24.04 ships 1.14.1. _Podman_ v5.8.1 requires at least `crun` 1.14.3. Every `podman run` fails with `OCI runtime error: crun: unknown version specified` if `crun` is too old. The snap builds `crun` 1.19.1 from source.

### `netavark` and `aardvark-dns` Not in Ubuntu 22.04

These packages were added in Ubuntu 23.10. The snap downloads pre-built binaries from GitHub Releases (`netavark` v1.14.1, `aardvark-dns` v1.14.0). These binaries require only `glibc` 2.34.

### `passt`/`pasta` Not Available on Ubuntu 22.04

_Podman_ v5.8.1 defaults to `pasta` for rootless networking, but `passt` was added in Ubuntu 23.04. The snap's `containers.conf` sets `default_rootless_network_cmd = "slirp4netns"` to use the bundled `slirp4netns` instead.

### `LD_LIBRARY_PATH` Does Not Propagate Through `conmon` → `crun`

The wrapper sets `LD_LIBRARY_PATH` for _Podman_, but when _Podman_ spawns `conmon`, which then spawns `crun`, the library path is lost. The snap bundles `libyajl` (required by `crun`), but `crun` can't find it at runtime. Fix: `containers.conf` points at `conmon-wrapper` and `crun-wrapper` scripts that set `LD_LIBRARY_PATH` before exec'ing the real binaries. This scopes library resolution to the snap's own processes without affecting the host.

### `LD_LIBRARY_PATH` Not Propagated to Healthcheck Transient Units

_Podman_ creates transient systemd timer and service units for container healthchecks. It reads `/proc/self/exe` to determine its own binary path and embeds that in the transient unit's `ExecStart`. After the shim `exec()`s the real binary, `/proc/self/exe` resolves to the raw snap path — bypassing the shim's `LD_LIBRARY_PATH` setup. There is no upstream configuration option or environment variable to override this path.

Fix: a 3-line patch (`patches/healthcheck-ld-library-path.patch`) to `libpod/healthcheck_linux.go` that propagates `LD_LIBRARY_PATH` via `systemd-run --setenv`, mirroring the existing `PATH` propagation. This is the only upstream source modification in the snap. See [HEALTHCHECK_ISSUES.md](HEALTHCHECK_ISSUES.md) for the full root cause analysis, including why alternative approaches (`ldconfig`, compiled wrapper, user environment generator, transient unit monitor) were rejected.

### `uidmap` and `dbus-user-session` Required on Host for Rootless

The `uidmap` package (provides `newuidmap`/`newgidmap`) and `dbus-user-session` are not bundled in the snap — they must exist on the host and are accessed through classic confinement. `uidmap` provides setuid binaries for user namespace creation; `dbus-user-session` provides the D-Bus user session bus needed for `XDG_RUNTIME_DIR` and rootless session management. Ubuntu Desktop includes both by default, but server installs, minimal images, and LXD containers do not. If a user removes the apt-installed `podman`, `uidmap` is auto-removed with it. Rootless will fail until it is reinstalled.

### `libgpg-error` Required on Fedora/CentOS

The snap bundles `libgpgme` but not its dependency `libgpg-error`. On Fedora and CentOS this library must be present on the host (`dnf install libgpg-error`). On Debian/Ubuntu it is typically already installed as a dependency of other system packages.

### `iptables` Not Found on Non-Ubuntu Hosts

`netavark` calls `iptables` as a child process of `conmon`. On Ubuntu, `iptables` is always present. On Debian 12, CentOS 9, and Fedora 42 (which use `nftables` natively), `iptables` must be installed on the host. The `nftables` driver (`firewall_driver = "nftables"`) was attempted but fails in LXD on WSL2 due to missing kernel modules.

### `OpenSSL` 3.0.x `-quiet` Flag (Test-Only)

The _Podman_ `BATS` test helpers use `-quiet` with `openssl req`, which was added in `OpenSSL` 3.2. Ubuntu 22.04 ships `OpenSSL` 3.0.x. The test setup patches `-quiet` to `-batch` in `helpers.bash`. This only affects tests, not the snap itself.

### `snapcraft` 7.x vs 8.x

`core22` snaps require `snapcraft` 7.x. The `02_build_snap.sh` script installs from the `7.x/stable` channel. `core22` uses `architectures:` instead of `platforms:` in the YAML schema.

### `AppArmor` User Namespace Restriction (Ubuntu 24.04)

Ubuntu 24.04 restricts unprivileged user namespaces via `apparmor_restrict_unprivileged_userns=1`. _Podman_ itself is unaffected (uses setuid helpers), but `skopeo`'s `unshare()` call fails. The test setup disables this restriction where present.

## Modifying the Snap

To change what's bundled or how it's built, edit `snapcraft.yaml`. To test changes:

```bash
# Rebuild
/usr/bin/sg lxd -c "lxc delete --force m0x41-podman-build"
/usr/bin/sg lxd -c "./scripts/01_launch.sh"

# Test
/usr/bin/sg lxd -c "lxc delete --force m0x41-podman-test"
/usr/bin/sg lxd -c "./scripts/03_test_launch.sh all"
```

The build container caches nothing — deleting and recreating it gives a clean build every time.

## Architecture

```
Host (WSL2)                          LXD Build Container          LXD Test Container(s)
─────────────                        ──────────────────           ────────────────────
01_launch.sh
  ├─ creates container ──────────>   02_build_snap.sh
  ├─ pushes snapcraft project          └─ snapcraft --destructive-mode
  └─ pulls built .snap

03_test_launch.sh
  ├─ creates test container ──────────────────────────────>   04_test_setup.sh
  ├─ pushes .snap + scripts                                    ├─ snap install --classic
  └─ triggers tests                                            ├─ creates test user
                                                               └─ policy.json
                                                             05_run_tests.sh [tier1..5|all]

06_test_multi_distro.sh                                      LXD Containers (per distro)
  ├─ iterates distro matrix ──────────────────────────────>  07_test_setup_multi.sh
  ├─ pushes .snap + scripts (parallel)                         ├─ installs snapd
  └─ runs tiers 1-3, 5 per distro                               ├─ snap install --classic
                                                               └─ creates test user
                                                             05_run_tests.sh [tier1..3, tier5]

08_wrapper_test_launch.sh                                    LXD Containers (per distro)
  ├─ iterates distro matrix ──────────────────────────────>  09_wrapper_test_setup.sh
  ├─ pushes .snap + scripts (parallel)                         ├─ installs snapd (no rootless deps)
  └─ runs wrapper tests per distro                             ├─ snap install --classic
                                                               └─ creates test user
                                                             10_wrapper_tests.sh [18 tests]
```
