# Changelog

All notable changes to the `m0x41-podman` snap package are documented here.

Version format: `{upstream_podman_version}+snap{N}` — the suffix tracks snap packaging revisions independent of the upstream _Podman_ release.

## v5.8.1+snap1

Initial release.

**Upstream:** [Podman v5.8.1 release notes](https://github.com/containers/podman/releases/tag/v5.8.1)

### Bundled Components

| Component | Version | Source |
|-----------|---------|--------|
| Podman (with Quadlet) | v5.8.1 | Built from source |
| crun | 1.19.1 | Built from source |
| conmon | 2.0.26 | Built from source |
| netavark | 1.14.1 | Pre-built binary |
| aardvark-dns | 1.14.0 | Pre-built binary |
| catatonit, fuse-overlayfs, slirp4netns, iptables | core22 | Staged from Ubuntu 22.04 |

### Features

- Classic confinement snap on `core22` (Ubuntu 22.04) base
- Rootless and rootful operation
- Full Quadlet (systemd integration) support with auto-registered generators
- Install hook places `podman` on PATH at `/usr/local/bin/podman`
- Bundled man pages, systemd socket units, and container policy
- Tested across Ubuntu 22.04, Ubuntu 24.04, Debian 12, CentOS 9 Stream, and Fedora 43

### Patches Applied

- **Healthcheck LD_LIBRARY_PATH** — propagates `LD_LIBRARY_PATH` into healthcheck transient units so that snap-bundled libraries are visible to `conmon` and `crun` when systemd executes healthcheck timers
- **Generate systemd binary path** — overrides the binary path in `podman generate systemd` output via `PODMAN_BINARY` so generated units reference the `/usr/local/bin/podman` shim rather than the snap-internal path
