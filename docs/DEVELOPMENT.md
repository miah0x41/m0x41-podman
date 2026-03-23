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
   - Clones and builds _Podman_ v5.8.1 from source
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
| `podman` | nil | Clones _Podman_ v5.8.1, builds `podman`, `podman-remote`, `rootlessport`, `quadlet` |
| `configs` | dump | Copies `containers.conf`, `storage.conf`, `registries.conf`, `policy.json` into the snap |
| `wrapper` | dump | Copies the `podman-wrapper` shell script that sets `PATH` and `LD_LIBRARY_PATH` |

### The Wrapper Script

The snap entry point is `bin/podman-wrapper`, not the _Podman_ binary directly. The wrapper:

1. Prepends the snap's binary directories to `PATH` so _Podman_ can find `netavark`, `aardvark-dns`, `conmon`, etc.
2. Sets `LD_LIBRARY_PATH` so _Podman_ can find bundled shared libraries (`libgpgme`, `libyajl`, etc.)
3. Execs the real `podman` binary

Child processes spawned by `conmon` (e.g. `crun`) don't inherit `LD_LIBRARY_PATH`, which is why the test setup also registers the snap's library directory with `ldconfig`.

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
| `04_test_setup.sh` | Test container | Installs the snap, creates a test user with subuid/subgid ranges, registers bundled libraries via `ldconfig`, installs `Go`/`BATS`/_Podman_ source for tier 4 |
| `05_run_tests.sh` | Test container | Four-tier test runner. Accepts `tier1`, `tier2`, `tier3`, `tier4`, or `all` |
| `06_test_multi_distro.sh` | Host | Launches five distro containers in parallel, pushes the snap to each, runs tiers 1-3 on all, prints a summary table |
| `07_test_setup_multi.sh` | Test container | Distro-agnostic setup — detects the distro, installs `snapd` and prerequisites, installs the snap, creates the test user. Handles Ubuntu, Debian, Fedora, and CentOS/RHEL |
| `podman-wrapper` | Inside snap | Entry point script that sets `PATH` and `LD_LIBRARY_PATH` before exec'ing _Podman_ |

## Key Compatibility Issues

These are non-obvious problems discovered during development. They are handled in the build and test scripts but documented here for anyone modifying the project.

### `crun` Version Floor

Ubuntu 22.04 ships `crun` 1.8.x; Ubuntu 24.04 ships 1.14.1. _Podman_ v5.8.1 requires at least `crun` 1.14.3. Every `podman run` fails with `OCI runtime error: crun: unknown version specified` if `crun` is too old. The snap builds `crun` 1.19.1 from source.

### `netavark` and `aardvark-dns` Not in Ubuntu 22.04

These packages were added in Ubuntu 23.10. The snap downloads pre-built binaries from GitHub Releases (`netavark` v1.14.1, `aardvark-dns` v1.14.0). These binaries require only `glibc` 2.34.

### `passt`/`pasta` Not Available on Ubuntu 22.04

_Podman_ v5.8.1 defaults to `pasta` for rootless networking, but `passt` was added in Ubuntu 23.04. The snap's `containers.conf` sets `default_rootless_network_cmd = "slirp4netns"` to use the bundled `slirp4netns` instead.

### `LD_LIBRARY_PATH` Does Not Propagate Through `conmon` → `crun`

The wrapper sets `LD_LIBRARY_PATH` for _Podman_, but when _Podman_ spawns `conmon`, which then spawns `crun`, the library path is lost. The snap bundles `libyajl` (required by `crun`), but `crun` can't find it at runtime. Fix: register the snap's library directory system-wide via `ldconfig` during setup.

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
                                                               └─ ldconfig + policy.json
                                                             05_run_tests.sh [tier1..4|all]

06_test_multi_distro.sh                                      LXD Containers (per distro)
  ├─ iterates distro matrix ──────────────────────────────>  07_test_setup_multi.sh
  ├─ pushes .snap + scripts (parallel)                         ├─ installs snapd
  └─ runs tiers 1-3 per distro                                 ├─ snap install --classic
                                                               └─ creates test user
                                                             05_run_tests.sh [tier1..3]
```
