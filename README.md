# Podman Snap (Classic Confinement)

_Podman_ v5.8.1 packaged as a classic confinement snap, built on `core22` (Ubuntu 22.04). Tested across five Linux distributions in both _rootless_ and _rootful_ modes.

This project exists because there is no official _Podman_ snap, and previous community attempts have stalled:

- [Snap Package](https://github.com/containers/podman/discussions/14360) issue on `containers/podman`. Maintainer comment from 2022: _"This is an opensource project, if community wants to maintain SNAP or Flatpak we are fine with that."_
- [Podman Snap Store Listing](https://snapcraft.io/podman) — non-functional listing from 2020.
- [Forum Discussion](https://forum.snapcraft.io/t/running-snapcraft-with-podman/9016) from Dec 2018.
- [podman-snap](https://github.com/abitrolly/podman-snap) attempt from 2019.
- [Forum Discussion](https://forum.snapcraft.io/t/is-anyone-working-on-a-newer-snap-for-podman/28594) from Feb 2022.
- [Forum Discussion](https://forum.snapcraft.io/t/please-remove-defunct-snap-store-listing/34289) from Mar 2023.
- [Forum Discussion](https://forum.snapcraft.io/t/need-podman-app/38450) from Jan 2024.

## Potential Related Projects

- [mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static?tab=readme-ov-file) — _Podman_ static builds.

## Distro Compatibility

Tested 2026-03-19. The snap runs on any Linux distribution with `glibc` >= 2.34 and `snapd`. Rootless mode requires `uidmap` and `dbus-user-session` on the host (provides `newuidmap`/`newgidmap` and the D-Bus user session bus). These are installed by default on Ubuntu Desktop but not on server or minimal installs — run `sudo apt install uidmap dbus-user-session` if missing. Fedora and CentOS also need `libgpg-error` (the snap bundles `libgpgme` but not this dependency).

### Rootless

| Distro | `glibc` | Status | Host packages required |
|--------|---------|--------|------------------------|
| Ubuntu 22.04 | 2.35 | Pass | None |
| Ubuntu 24.04 | 2.39 | Pass | None |
| Debian 12 | 2.36 | Pass | None |
| CentOS 9 Stream | 2.34 | Pass | None |
| Fedora 42 | 2.41 | Fail | — |
| Ubuntu 20.04 | 2.31 | Fail | — |

Fedora 42 fails because `newuidmap` lacks the setuid bit inside LXD containers. This is an LXD/Fedora environment limitation — rootless would work on a real Fedora host with setuid `newuidmap`. Full Fedora validation on bare metal is pending.

Ubuntu 20.04 fails because `glibc` 2.31 is below the snap's minimum of 2.34.

### Rootful

| Distro | `glibc` | Status | Host packages required |
|--------|---------|--------|------------------------|
| Ubuntu 22.04 | 2.35 | Pass | None |
| Ubuntu 24.04 | 2.39 | Pass | None |
| Debian 12 | 2.36 | Pass | `apt install iptables` |
| CentOS 9 Stream | 2.34 | Pass | `dnf install iptables-nft` |
| Fedora 42 | 2.41 | Pass | `dnf install iptables-nft` |
| Ubuntu 20.04 | 2.31 | Fail | — |

Debian 12, CentOS 9, and Fedora 42 require `iptables` on the host. `netavark` (the container network backend) calls `iptables` as a child process of `conmon`, which does not inherit the snap's `PATH`. These distros ship `nftables` natively and do not include an `iptables` command by default.

## Quick Start

### Install from a Local Build

```bash
sudo snap install m0x41-podman_5.8.1_amd64.snap --dangerous --classic
```

### Build the Snap Yourself

Requires LXD. The build runs inside an LXD container — no root access needed on the host.

```bash
/usr/bin/sg lxd -c "./scripts/01_launch.sh"
```

This creates an LXD container, builds the snap with `snapcraft --destructive-mode`, and pulls the `.snap` file back to the host.

### Run

The snap's install hook creates `/usr/local/bin/podman`, so `podman` is immediately available on PATH:

```bash
podman run --rm docker.io/library/alpine echo "hello from snap"
```

Alternatively, use the full snap command name: `m0x41-podman run ...`

### Quadlet (Systemd Integration)

Quadlet is supported out of the box. The install hook registers the systemd generators automatically. Create a `.container` file and reload:

```bash
sudo mkdir -p /etc/containers/systemd
sudo tee /etc/containers/systemd/my-app.container <<EOF
[Container]
Image=docker.io/library/nginx
PublishPort=8080:80

[Install]
WantedBy=default.target
EOF

sudo systemctl daemon-reload
sudo systemctl start my-app.service
```

See [docs/QUADLET.md](docs/QUADLET.md) for rootless usage, file locations, and limitations.

### First-Run Messages

On the first rootless invocation via `m0x41-podman`, the snap prints a welcome message. If host dependencies are missing, it prints a warning with the exact install command for your distro. See [docs/WRAPPER.md](docs/WRAPPER.md) for full details.

## How This Was Tested

The snap was developed through a structured process, with each stage informing the next:

### 1. Native Build from Source (Ubuntu 24.04)

Built _Podman_ v5.8.1 from source to establish a known-good baseline. Identified every compatibility fix needed versus stock Ubuntu 24.04: `crun` too old (1.14.1 → 1.19.1), `Go` not in repos (1.24.2), `OpenSSL` 3.0.x missing `-quiet` flag, `AppArmor` user namespace restrictions. Validated with a 5-tier test suite covering unit tests, rootless and rootful functional tests, upstream BATS tests, and API tests. All tiers pass in both LXD containers and VMs.

### 2. Strict Confinement Snap (Failed)

Attempted strict confinement first — the preferred approach for snap security. The snap built correctly but **cannot run containers**: snap's mount namespace hides the host's setuid `newuidmap`/`newgidmap` binaries, which are required for rootless user namespace creation. There is no workaround — staging the binaries strips setuid, `squashfs` uses `nosuid`, and file capabilities are also stripped. Six distinct constraints were documented. See [Why Classic Confinement?](#why-classic-confinement) below.

### 3. Classic Confinement Snap (core24)

Switched to classic confinement, which bypasses the mount namespace entirely. All 21 functional tests pass (7 command validation + 8 rootless + 6 rootful). 28 of 31 upstream `BATS` tests pass — the 3 failures are snap-specific configuration conflicts, not functional regressions. Results are identical in LXD containers and VMs.

However, `core24` builds against `glibc` 2.38, limiting the snap to Ubuntu 24.04 only. Older distros fail immediately.

### 4. Classic Confinement Snap (core22) — Widening Distro Support

Rebuilt on `core22` to lower the `glibc` floor. This required switching from Ubuntu apt packages to pre-built binaries for `netavark` and `aardvark-dns` (not in Ubuntu 22.04 repos), dropping `passt` in favour of `slirp4netns` for rootless networking, and using `snapcraft` 7.x instead of 8.x. The actual `glibc` floor turned out to be 2.34 — lower than the predicted 2.35 — discovered when CentOS 9 Stream passed all tests.

### 5. Multi-Distro Testing

Automated parallel testing across five distributions using LXD containers. Each distro gets a fresh container, the snap is installed, and tiers 1-3 are run. Four of five distros pass all 21 tests. The Fedora rootless failure was traced to a missing setuid bit on `newuidmap` inside LXD — an environment limitation, not a snap defect.

### 6. VM Testing

LXD VMs provide full kernel isolation (no shared kernel, no nesting flags), which is closer to bare-metal. The `core24` snap was validated in VMs with identical results to containers — 21/21 functional, 28/31 `BATS`.

## What's in the Snap

The snap bundles _Podman_ and all its runtime dependencies so that no additional packages are needed on the host, except `iptables` on non-Ubuntu distros, `uidmap` and `dbus-user-session` for rootless mode, and `libgpg-error` on Fedora/CentOS (see [Distro Compatibility](#distro-compatibility)):

| Component | Version | Source |
|-----------|---------|--------|
| `Podman` | v5.8.1 | Built from source |
| `crun` | 1.19.1 | Built from source |
| `netavark` | 1.14.1 | Pre-built binary |
| `aardvark-dns` | 1.14.0 | Pre-built binary |
| `conmon`, `catatonit`, `fuse-overlayfs`, `slirp4netns`, `iptables` | Ubuntu 22.04 | Packaged binaries |

See [docs/COMPONENTS.md](docs/COMPONENTS.md) for full details including licenses and upstream links.

## Why Classic Confinement?

Snap strict confinement replaces `/usr/bin` with the base snap's copy. The host's setuid `newuidmap` and `newgidmap` (from the `uidmap` package) — required for rootless user namespace creation — become invisible. Staging them inside the snap doesn't help: `snapcraft` strips setuid bits, and `squashfs` mounts with `nosuid`. Classic confinement is the only path to a functional _Podman_ snap. Note that `uidmap` and `dbus-user-session` must be installed on the host for rootless mode — they are not bundled in the snap, but accessed directly through classic confinement.

## Repository Structure and Documentation

```
snapcraft.yaml                  # Snap definition (core22, classic confinement)
snap/                           # Bundled container engine configuration
  hooks/install                 # Install hook (shim, generators, ldconfig, policy.json)
  hooks/remove                  # Remove hook (cleanup)
scripts/                        # Build, test, and multi-distro automation
docs/
  DEVELOPMENT.md                # Build environment and script reference
  TESTING.md                    # Test methodology and results
  COMPONENTS.md                 # Upstream components, versions, and licenses
  WRAPPER.md                    # Wrapper script behaviour, messages, and testing
  QUADLET.md                    # Quadlet (systemd integration) and install hooks
```

- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** — Build environment setup, prerequisites, script reference
- **[docs/TESTING.md](docs/TESTING.md)** — Test tiers, how to run tests, multi-distro methodology, results
- **[docs/COMPONENTS.md](docs/COMPONENTS.md)** — Upstream components, licenses, and source availability
- **[docs/WRAPPER.md](docs/WRAPPER.md)** — Wrapper script behaviour, first-run messages, dependency detection, and test results
- **[docs/QUADLET.md](docs/QUADLET.md)** — Quadlet support, install/remove hooks, shim vs wrapper, and test results

## Acknowledgements

This project is a thin layer of packaging and test automation. The real work is done by the upstream projects and their maintainers:

- **[Podman](https://github.com/containers/podman)** — the container engine at the heart of this snap, developed by the [Containers](https://github.com/containers) organisation (Red Hat and community contributors)
- **[crun](https://github.com/containers/crun)** — the fast, lightweight OCI runtime by Giuseppe Scrivano
- **[netavark](https://github.com/containers/netavark)** and **[aardvark-dns](https://github.com/containers/aardvark-dns)** — container networking and DNS
- **[conmon](https://github.com/containers/conmon)** — container monitor
- **[slirp4netns](https://github.com/rootless-containers/slirp4netns)** — rootless networking by Akihiro Suda
- **[fuse-overlayfs](https://github.com/containers/fuse-overlayfs)** — rootless storage by Giuseppe Scrivano
- **[catatonit](https://github.com/openSUSE/catatonit)** — minimal init for pods, by openSUSE

Without these projects there would be nothing to package. This repository contributes only the `snapcraft.yaml`, the build/test scripts, and the documentation of what it took to get them working together inside a snap.

## Sponsor

[![Curio Data Pro Ltd](banner.png)](https://blog.curiodata.pro/)

I want to recognise the support and resources provided by **[Curio Data Pro Ltd](https://blog.curiodata.pro/)**, a data consultancy serving engineering sectors including Rail, Naval Design, Aviation, and Offshore Energy. Curio Data Pro combines 20+ years of Chartered Engineer experience across Aerospace, Defence, Rail, and Offshore Energy with data science and DevOps capabilities.

[Blog](https://blog.curiodata.pro/) | [LinkedIn](https://www.linkedin.com/company/curio-data-pro-ltd/)

## License

The original work in this repository (scripts, configuration, documentation) is licensed under the [Apache License 2.0](LICENSE).

The snap bundles binaries from upstream projects under Apache-2.0 and GPL-2.0 licenses. See [docs/COMPONENTS.md](docs/COMPONENTS.md) for details.

## Use of Text Generators

Whilst the `snapcraft.yaml` has not been constructed using _Text Generators_ (e.g. _Large Language Models_ (LLMs) or so-called "Artificial Intelligence" tools) they have been used extensively to automate the build and test of the package across hundreds of containers and _Virtual Machines_.
