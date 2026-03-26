# Unofficial Podman Snap Package

_Podman_ v5.8.1 with full _Quadlet_ (systemd integration) support, packaged as a classic confinement snap on `core22` (Ubuntu 22.04). Bundles all runtime dependencies — no additional packages needed on the host beyond `uidmap` for rootless mode. Tested end-to-end across five Linux distributions in both _rootless_ and _rootful_ modes.

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

## Quick Start

```bash
sudo snap install m0x41-podman_5.8.1_amd64.snap --dangerous --classic
```

The snap's install hook places `podman` on PATH at `/usr/local/bin/podman` and registers systemd generators for Quadlet. Both happen automatically — no manual configuration needed.

> **Note:** If you already have `podman` installed via `apt` or another package manager, the snap's `/usr/local/bin/podman` will take precedence on PATH (since `/usr/local/bin` is searched before `/usr/bin`). Remove the existing installation first, or use the snap command name `m0x41-podman` to avoid conflicts.

```bash
podman run --rm docker.io/library/alpine echo "hello from snap"
```

For rootless mode on server or minimal installs, you may need: `sudo apt install uidmap dbus-user-session`

### Podman API Socket

Tools like Traefik, Dozzle, and Beszel require the Podman API socket. The install hook registers the socket unit files; enable the socket with:

```bash
systemctl --user enable --now podman.socket
```

### Migrating from `apt`-Installed Podman

If you previously had _Podman_ installed via `apt`, you must clean up stale network state after switching to the snap. The old `aardvark-dns` process holds references to a different network namespace, breaking inter-container routing.

```bash
sudo apt remove podman
podman stop --all
pkill aardvark-dns
rm -rf /run/user/$(id -u)/containers/networks/aardvark-dns
systemctl --user restart podman.socket
```

Then restart your container services. If you had previously enabled `podman.socket`, re-enable it — the snap provides its own unit files that replace the ones removed with the `apt` package.

## Quadlet (Systemd Integration)

_Podman_ 5.x includes _Quadlet_ — a native mechanism for running containers as systemd services. This snap supports Quadlet out of the box, with systemd generators registered automatically by the install hook. Both rootful and rootless Quadlet are supported.

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

Quadlet has been validated end-to-end: the snap's install hook creates a `/usr/local/bin/podman` shim and registers the `podman-system-generator` and `podman-user-generator` with systemd. Live Quadlet services have been tested in both rootful and rootless modes across all supported distributions — containers start, run, and stop correctly as systemd units.

See [docs/QUADLET.md](docs/QUADLET.md) for rootless usage, file locations, the shim vs wrapper distinction, and detailed test results.

> **Note:** `podman generate systemd` is deprecated upstream and is not supported by this snap. It hardcodes revision-specific snap paths that break on refresh. Use Quadlet `.container` files instead.

## Distro Compatibility

Tested 2026-03-24. The snap runs on any Linux distribution with `glibc` >= 2.34 and `snapd`.

### Rootless

| Distro | `glibc` | Status | Host packages required |
|--------|---------|--------|------------------------|
| Ubuntu 22.04 | 2.35 | Pass | `apt install uidmap dbus-user-session` |
| Ubuntu 24.04 | 2.39 | Pass | `apt install uidmap dbus-user-session` |
| Debian 12 | 2.36 | Pass | `apt install uidmap dbus-user-session` |
| CentOS 9 Stream | 2.34 | Pass | `dnf install shadow-utils` |
| Fedora 42 | 2.41 | Fail | — |
| Ubuntu 20.04 | 2.31 | Fail | — |

Ubuntu Desktop includes `uidmap` and `dbus-user-session` by default. Server, minimal, and container images do not.

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

## What's in the Snap

The snap bundles _Podman_ and all its runtime dependencies so that no additional packages are needed on the host, except `iptables` on non-Ubuntu distros and `uidmap` + `dbus-user-session` for rootless mode (see [Distro Compatibility](#distro-compatibility)):

| Component | Version | Source |
|-----------|---------|--------|
| `Podman` (with `quadlet`) | v5.8.1 | Built from source |
| `crun` | 1.19.1 | Built from source |
| `netavark` | 1.14.1 | Pre-built binary |
| `aardvark-dns` | 1.14.0 | Pre-built binary |
| `conmon`, `catatonit`, `fuse-overlayfs`, `slirp4netns`, `iptables` | Ubuntu 22.04 | Packaged binaries |

The snap's install hook automatically:
- Creates `/usr/local/bin/podman` (so `podman` is on PATH without aliasing)
- Registers systemd generators (so Quadlet works immediately)
- Configures bundled library paths via `ldconfig`
- Installs `policy.json` at `/etc/containers/policy.json`

See [docs/COMPONENTS.md](docs/COMPONENTS.md) for full details including licenses and upstream links.

## Build

Requires LXD. The build runs inside an LXD container — no root access needed on the host.

```bash
/usr/bin/sg lxd -c "./scripts/01_launch.sh"
```

This creates an LXD container, builds the snap with `snapcraft --destructive-mode`, and pulls the `.snap` file back to the host. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for build details, script reference, and compatibility issues.

## Testing

The snap is validated with a five-tier test suite covering command validation, rootless and rootful functional tests, upstream BATS parity, and Quadlet/install hook validation. All tiers run automatically in LXD containers across five distributions.

| Tier | Tests | What It Validates |
|------|-------|-------------------|
| 1 | 7 | Snap binary, component versions, config paths |
| 2 | 8 | Rootless: pull, run, build, pod, volume, DNS |
| 3 | 6 | Rootful: run, build, pod, volume |
| 4 | 31 | Upstream BATS smoke tests |
| 5 | 18+ | Install hook artefacts (including socket units), Quadlet dry-run, live rootful and rootless Quadlet services, upstream BATS system-service, socket-activation, and quadlet tests, Go e2e quadlet tests |

The full upstream BATS suite (78 files, 782 tests) can also be run against the snap. Of the 782 tests, 480 pass, 176 are skipped (SELinux, `pasta`, checkpoint), and 126 fail — categorised as snap-specific (31), LXD-limited (3), missing infrastructure (20), or requiring investigation (72). See [docs/TESTING.md](docs/TESTING.md) for the full categorised results, multi-distro tables, and known failures.

## Why Classic Confinement?

Snap strict confinement replaces `/usr/bin` with the base snap's copy. The host's setuid `newuidmap` and `newgidmap` (from the `uidmap` package) — required for rootless user namespace creation — become invisible. Staging them inside the snap doesn't help: `snapcraft` strips setuid bits, and `squashfs` mounts with `nosuid`. Classic confinement also enables the install hook to register systemd generators for Quadlet and place the `podman` shim on PATH — operations that strict confinement does not permit. See [docs/CLASSIC_CONFINEMENT.md](docs/CLASSIC_CONFINEMENT.md) for the full technical justification and evaluation of existing snapd interfaces.

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

- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** — Build environment, prerequisites, script reference, architecture diagram
- **[docs/TESTING.md](docs/TESTING.md)** — Test tiers, how to run tests, multi-distro methodology, results
- **[docs/COMPONENTS.md](docs/COMPONENTS.md)** — Upstream components, licenses, and source availability
- **[docs/WRAPPER.md](docs/WRAPPER.md)** — Wrapper behaviour, first-run messages, dependency detection
- **[docs/QUADLET.md](docs/QUADLET.md)** — Quadlet support, install/remove hooks, shim vs wrapper

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
