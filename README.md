<div align="center">

# m0x41-podman

#### Unofficial _Podman_ snap package with full _Quadlet_ support — classic confinement on `core22`.

[![Build](https://img.shields.io/github/actions/workflow/status/miah0x41/m0x41-podman/build-snap.yml?label=build&logo=github)](https://github.com/miah0x41/m0x41-podman/actions/workflows/build-snap.yml)
[![Release](https://img.shields.io/github/v/release/miah0x41/m0x41-podman?logo=github)](https://github.com/miah0x41/m0x41-podman/releases/latest)
[![License](https://img.shields.io/github/license/miah0x41/m0x41-podman)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/miah0x41/m0x41-podman/total?logo=github&label=downloads)](https://github.com/miah0x41/m0x41-podman/releases)
[![Stars](https://img.shields.io/github/stars/miah0x41/m0x41-podman?logo=github)](https://github.com/miah0x41/m0x41-podman/stargazers)

[![Podman](https://img.shields.io/badge/Podman-v5.8.1-892CA0?logo=podman&logoColor=white)](https://github.com/containers/podman)
[![snap base](https://img.shields.io/badge/snap%20base-core22-E95420?logo=ubuntu&logoColor=white)](https://snapcraft.io/docs/base-snaps)
[![Platform](https://img.shields.io/badge/platform-linux--amd64-informational)](#distro-compatibility)
[![Signed](https://img.shields.io/badge/signed-cosign-blue?logo=sigstore&logoColor=white)](#verification)
[![SLSA](https://img.shields.io/badge/SLSA-Level%203-green)](https://slsa.dev/)

[Installation](#installation) • [Quadlet](#quadlet-systemd-integration) • [Compatibility](#distro-compatibility) • [Differences](#differences-from-native-podman) • [Documentation](#documentation) • [Releases](https://github.com/miah0x41/m0x41-podman/releases)

</div>

---

_Podman_ v5.8.1 with full _Quadlet_ (systemd integration) support, packaged as a classic confinement snap on `core22` (Ubuntu 22.04). Bundles all runtime dependencies — no additional packages needed on the host beyond `uidmap` for rootless mode. Tested end-to-end across five Linux distributions in both _rootless_ and _rootful_ modes.

## Installation

Download the latest release from [GitHub Releases](https://github.com/miah0x41/m0x41-podman/releases) and install:

```bash
# Download the latest release
curl -fsSL -o m0x41-podman.snap \
  "https://github.com/miah0x41/m0x41-podman/releases/latest/download/m0x41-podman_5.8.1+snap2_amd64.snap"

# Install
sudo snap install m0x41-podman.snap --dangerous --classic
```

The `--dangerous` flag is required because the snap is sideloaded from GitHub rather than the Snap Store (see [Snap Store Status](#snap-store-status)). The `--classic` flag grants the host filesystem access that _Podman_ requires for rootless operation and systemd integration.

The snap's install hook places `podman` on PATH at `/usr/local/bin/podman` and registers systemd generators for Quadlet. Both happen automatically — no manual configuration needed.

> **Note:** If you already have `podman` installed via `apt` or another package manager, the snap's `/usr/local/bin/podman` will take precedence on PATH (since `/usr/local/bin` is searched before `/usr/bin`). Remove the existing installation first, or use the snap command name `m0x41-podman` to avoid conflicts.

```bash
podman run --rm docker.io/library/alpine echo "hello from snap"
```

For rootless mode on server or minimal installs, you may need: `sudo apt install uidmap dbus-user-session`

### Verification

Each release includes a SHA256 checksum, a [cosign](https://docs.sigstore.dev/cosign/overview/) signature bundle, and a [SLSA provenance](https://slsa.dev/) attestation. These let you verify that the snap was not tampered with and was built by the GitHub Actions workflow in this repository.

```bash
# Download the checksum and signature bundle
curl -fsSL -o m0x41-podman.snap.sha256 \
  "https://github.com/miah0x41/m0x41-podman/releases/latest/download/m0x41-podman_5.8.1+snap2_amd64.snap.sha256"
curl -fsSL -o m0x41-podman.snap.cosign-bundle \
  "https://github.com/miah0x41/m0x41-podman/releases/latest/download/m0x41-podman_5.8.1+snap2_amd64.snap.cosign-bundle"

# Integrity — verify the file was not corrupted or modified
sha256sum -c m0x41-podman.snap.sha256

# Authenticity — verify the file was signed by this repository's workflow (requires cosign)
cosign verify-blob m0x41-podman.snap \
  --bundle m0x41-podman.snap.cosign-bundle \
  --certificate-identity-regexp "https://github.com/miah0x41/m0x41-podman" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"

# Provenance — verify the file was built from a specific commit (requires gh >= 2.49.0)
gh attestation verify m0x41-podman.snap \
  --owner miah0x41
```

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

> **Note:** `podman generate systemd` is deprecated upstream. The snap's `PODMAN_BINARY` patch makes it functional (generated units correctly reference the shim), but Quadlet is the supported path forward. Use Quadlet `.container` files for new deployments.

## Differences from Native _Podman_

The snap is not a drop-in replacement for a natively installed _Podman_. These are the most significant differences — see [docs/USER.md](docs/USER.md) for the complete user guide.

**Rootless networking uses `slirp4netns`, not `pasta`.** Native _Podman_ v5.x defaults to `pasta` for faster rootless networking. The snap uses `slirp4netns` because `pasta` is not available on the `core22` base. Rootless networking works but may be slower, and `--network pasta` will fail.

**Configuration files in standard locations are ignored.** The snap sets `CONTAINERS_CONF`, `CONTAINERS_REGISTRIES_CONF`, and `CONTAINERS_STORAGE_CONF` to point to its own bundled configs. Any `containers.conf`, `storage.conf`, or `registries.conf` you place in `~/.config/containers/` or `/etc/containers/` will not be loaded. To customise `containers.conf` settings, use `CONTAINERS_CONF_OVERRIDE`:

```bash
export CONTAINERS_CONF_OVERRIDE="$HOME/.config/containers/overrides.conf"
```

There is no override mechanism for `storage.conf` or `registries.conf`. See [docs/USER.md](docs/USER.md#configuration) for which settings are safe to override and which will break the snap.

**Rootless mode requires host packages.** `uidmap` and `dbus-user-session` cannot be bundled (they require setuid bits and a system D-Bus service). Non-Ubuntu distros also need `iptables` for rootful networking. See [Distro Compatibility](#distro-compatibility) for per-distro install commands.

**Some features are not supported.** `podman machine`, `podman compose`, checkpoint/restore, and SELinux are not available. `podman generate systemd` is deprecated upstream — it works with the snap's `PODMAN_BINARY` patch but Quadlet is the preferred path forward.

**The install hook writes to the host filesystem.** It creates a shim at `/usr/local/bin/podman`, registers systemd generators, installs corrected systemd units, and symlinks man pages. See [docs/USER.md](docs/USER.md#install-hook-side-effects) for the full list. If a previous native _Podman_ installation is detected, the hook warns about stale artefacts and suggests cleanup — see [Replacing a Native Podman Install](docs/USER.md#replacing-a-native-podman-install).

**Architecture is `amd64` only** with a `glibc` >= 2.34 floor. Distros older than ~2021 are not supported.

## Distro Compatibility

Tested 2026-03-24. The snap runs on any Linux distribution with `glibc` >= 2.34 and `snapd`.

### Rootless

| Distro | `glibc` | Status | Host packages required |
|--------|---------|--------|------------------------|
| Ubuntu 22.04 | 2.35 | Pass | `apt install uidmap dbus-user-session` |
| Ubuntu 24.04 | 2.39 | Pass | `apt install uidmap dbus-user-session` |
| Debian 12 | 2.36 | Pass | `apt install uidmap dbus-user-session` |
| CentOS 9 Stream | 2.34 | Pass | `dnf install shadow-utils` |
| Fedora 43 | 2.41 | Fail | — |
| Ubuntu 20.04 | 2.31 | Fail | — |

Ubuntu Desktop includes `uidmap` and `dbus-user-session` by default. Server, minimal, and container images do not.

Fedora 43 fails because `newuidmap` lacks the setuid bit inside LXD containers. This is an LXD/Fedora environment limitation — rootless would work on a real Fedora host with setuid `newuidmap`. Full Fedora validation on bare metal is pending.

Ubuntu 20.04 fails because `glibc` 2.31 is below the snap's minimum of 2.34.

### Rootful

| Distro | `glibc` | Status | Host packages required |
|--------|---------|--------|------------------------|
| Ubuntu 22.04 | 2.35 | Pass | None |
| Ubuntu 24.04 | 2.39 | Pass | None |
| Debian 12 | 2.36 | Pass | `apt install iptables` |
| CentOS 9 Stream | 2.34 | Pass | `dnf install iptables-nft` |
| Fedora 43 | 2.41 | Pass | `dnf install iptables-nft` |
| Ubuntu 20.04 | 2.31 | Fail | — |

Debian 12, CentOS 9, and Fedora 43 require `iptables` on the host. `netavark` (the container network backend) calls `iptables` as a child process of `conmon`, which does not inherit the snap's `PATH`. These distros ship `nftables` natively and do not include an `iptables` command by default.

## What's in the Snap

The snap bundles _Podman_ and all its runtime dependencies so that no additional packages are needed on the host, except `iptables` on non-Ubuntu distros and `uidmap` + `dbus-user-session` for rootless mode (see [Distro Compatibility](#distro-compatibility)):

| Component | Version | Source |
|-----------|---------|--------|
| `Podman` (with `quadlet`) | v5.8.1 | Built from source |
| `crun` | 1.19.1 | Built from source |
| `conmon` | 2.0.26 | Built from source |
| `netavark` | 1.14.1 | Pre-built binary |
| `aardvark-dns` | 1.14.0 | Pre-built binary |
| `catatonit`, `fuse-overlayfs`, `slirp4netns`, `iptables` | Ubuntu 22.04 | Packaged binaries |

The snap's install hook automatically:
- Creates `/usr/local/bin/podman` (so `podman` is on PATH without aliasing)
- Registers systemd generators (so Quadlet works immediately)
- Installs `policy.json` at `/etc/containers/policy.json`

See [docs/COMPONENTS.md](docs/COMPONENTS.md) for full details including licenses and upstream links.

## Testing

The snap is validated with a seven-tier test suite covering command validation, rootless and rootful functional tests, upstream BATS parity, Quadlet/install hook validation, host-side impact, and the full upstream BATS suite. Tiers 1-5 form the core regression suite. Tier 6 requires a VM. Tier 7 is on-demand.

| Tier | Tests | What It Validates |
|------|-------|-------------------|
| 1 | 7 | Snap binary, component versions, config paths |
| 2 | 8 | Rootless: pull, run, build, pod, volume, DNS |
| 3 | 6 | Rootful: run, build, pod, volume |
| 4 | 31 | Upstream BATS smoke tests |
| 5 | 20+ | Install hook artefacts (including socket units, man pages), Quadlet dry-run, live rootful and rootless Quadlet, upstream BATS system-service/socket-activation/quadlet tests, healthcheck transient unit validation |
| 6 | 25+ | Network integrity, library path poisoning, systemd health, reboot survival, snap removal cleanup (VM only) |
| 7 | 785 | Full upstream BATS suite in root and rootless modes (on-demand) |

The full upstream BATS suite (78 files, 785 tests) can also be run against the snap. Of those, 180 are skipped by the test harness — tests for `pasta` networking (the snap bundles `slirp4netns` instead), SELinux, checkpoint/restore, and SSH/remote, none of which the snap ships. Of the **605 applicable tests** that run in root mode, **559 pass (92%)** unmodified. A second adapted pass — where the shim respects pre-existing config env vars — recovers 5 more, for **564/605 (93%)**. The `PODMAN_BINARY` patch recovers a further 16 tests (`generate systemd` and `runlabel` binary path failures), bringing the combined total to **~580/605 (~96%)**. The remaining ~25 residual failures are snap-specific: config env var override, missing infrastructure, and timing. In rootless mode, the same `pasta` tests that skip in root mode instead fail (91 tests), inflating the raw failure count. Excluding these, rootless passes **511/611 applicable tests (84%)**. See [docs/TEST-FAILURES.md](docs/TEST-FAILURES.md) for the full per-tier breakdown, [docs/TESTING.md](docs/TESTING.md) for the methodology, and [docs/TESTING-RESULTS.md](docs/TESTING-RESULTS.md) for recorded results.

## Build

Requires LXD. The build runs inside an LXD container — no root access needed on the host.

```bash
/usr/bin/sg lxd -c "./scripts/01_launch.sh"
```

This creates an LXD container, builds the snap with `snapcraft --destructive-mode`, and pulls the `.snap` file back to the host. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for build details, script reference, and compatibility issues.

## Why Classic Confinement?

Snap strict confinement replaces `/usr/bin` with the base snap's copy. The host's setuid `newuidmap` and `newgidmap` (from the `uidmap` package) — required for rootless user namespace creation — become invisible. Staging them inside the snap doesn't help: `snapcraft` strips setuid bits, and `squashfs` mounts with `nosuid`. Classic confinement also enables the install hook to register systemd generators for Quadlet and place the `podman` shim on PATH — operations that strict confinement does not permit. See [docs/CLASSIC_CONFINEMENT.md](docs/CLASSIC_CONFINEMENT.md) for the full technical justification and evaluation of existing snapd interfaces.

## Snap Store Status

A classic confinement request was submitted to the Snap Store but was not granted. The [forum discussion](https://forum.snapcraft.io/t/m0x41-podman-unofficial-podman-snap-package/50805) has the full details. As a result, this snap cannot be published to the Snap Store and must be sideloaded from [GitHub Releases](https://github.com/miah0x41/m0x41-podman/releases) using `--dangerous --classic`.

This means automatic updates via `snapd` are not available. To upgrade, download the new release and re-install:

```bash
sudo snap install m0x41-podman_<version>_amd64.snap --dangerous --classic
```

## Background

This project exists because there is no official _Podman_ snap, and previous community attempts have stalled.

<details>
<summary>Previous attempts and forum discussions</summary>

- [Snap Package](https://github.com/containers/podman/discussions/14360) issue on `containers/podman`. Maintainer comment from 2022: _"This is an opensource project, if community wants to maintain SNAP or Flatpak we are fine with that."_
- [Podman Snap Store Listing](https://snapcraft.io/podman) — non-functional listing from 2020.
- [Forum Discussion](https://forum.snapcraft.io/t/running-snapcraft-with-podman/9016) from Dec 2018.
- [podman-snap](https://github.com/abitrolly/podman-snap) attempt from 2019.
- [Forum Discussion](https://forum.snapcraft.io/t/is-anyone-working-on-a-newer-snap-for-podman/28594) from Feb 2022.
- [Forum Discussion](https://forum.snapcraft.io/t/please-remove-defunct-snap-store-listing/34289) from Mar 2023.
- [Forum Discussion](https://forum.snapcraft.io/t/need-podman-app/38450) from Jan 2024.

</details>

**Related projects**

- [mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static?tab=readme-ov-file) — _Podman_ static builds.

## Feedback and Community Adoption

Pull requests are not being accepted — this repository is maintained as a personal packaging effort. Feedback, bug reports, and feature requests are welcome:

- **Bugs and feature requests** — [Open an issue](https://github.com/miah0x41/m0x41-podman/issues)
- **General discussion** — [Snapcraft forum thread](https://forum.snapcraft.io/t/m0x41-podman-unofficial-podman-snap-package/50805)

This repository is licensed under the [Apache License 2.0](LICENSE). Anyone in the snapcraft community is welcome to fork it and maintain a _Podman_ snap under their own name or as part of an official effort. If a formally maintained _Podman_ snap becomes available on the Snap Store, this repository will be deprecated in its favour.

## Documentation

```
snapcraft.yaml                  # Snap definition (core22, classic confinement)
patches/                        # Upstream source patches applied at build time
snap/                           # Bundled container engine configuration
  hooks/install                 # Install hook (shim, generators, man pages, policy.json)
  hooks/remove                  # Remove hook (cleanup)
scripts/                        # Build, test, upgrade, and multi-distro automation
docs/
  USER.md                       # User guide: snap vs native Podman differences
  DEVELOPMENT.md                # Build environment, script reference, and release process
  TESTING.md                    # Test methodology: tiers, how to run tests
  TESTING-RESULTS.md            # Recorded test results, known failures, BATS suite
  TEST-FAILURES.md              # All known failures by tier and environment (LXC vs VM)
  COMPONENTS.md                 # Upstream components, versions, and licenses
  WRAPPER.md                    # Wrapper script behaviour, messages, and testing
  QUADLET.md                    # Quadlet (systemd integration) and install hooks
  CLASSIC_CONFINEMENT.md        # Classic confinement request and rationale
  investigations/               # Root cause analyses and security reviews
    RCCA-BATS-FAILURES.md       # BATS test failure root cause analysis
    RCCA-ADAPTED-FAILURES.md    # Adapted pass residual failure analysis
    RCCA-LIBRARY-POISONING.md   # Snap library path poisoning of host systemd services
    RCCA-GENERATE-SYSTEMD.md    # Generate systemd binary path resolution issue
    HEALTHCHECK_ISSUES.md       # Healthcheck transient unit issue
    PATCH_SECURITY_REVIEW.md    # Security review of healthcheck patch
    PATCH_SECURITY_REVIEW_BINARY_PATH.md  # Security review of binary path patch
```

- **[docs/USER.md](docs/USER.md)** — User guide: all differences from native _Podman_, configuration, limitations
- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** — Build environment, prerequisites, script reference, release process, architecture diagram
- **[docs/TESTING.md](docs/TESTING.md)** — Test tiers, how to run tests
- **[docs/TESTING-RESULTS.md](docs/TESTING-RESULTS.md)** — Recorded results, known failures, full upstream BATS suite analysis
- **[docs/TEST-FAILURES.md](docs/TEST-FAILURES.md)** — All known failures by tier and environment (LXC vs VM)
- **[docs/COMPONENTS.md](docs/COMPONENTS.md)** — Upstream components, licenses, and source availability
- **[docs/WRAPPER.md](docs/WRAPPER.md)** — Wrapper behaviour, first-run messages, dependency detection
- **[docs/QUADLET.md](docs/QUADLET.md)** — Quadlet support, install/remove hooks, shim vs wrapper
- **[docs/CLASSIC_CONFINEMENT.md](docs/CLASSIC_CONFINEMENT.md)** — Classic confinement rationale and interface evaluation
- **[docs/investigations/](docs/investigations/)** — Root cause analyses (BATS failures, adapted pass, library path poisoning, healthcheck issue, patch security review)

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
