# Changelog

All notable changes to the `m0x41-podman` snap package are documented here.

Version format: `{upstream_podman_version}+snap{N}` — the suffix tracks snap packaging revisions independent of the upstream _Podman_ release.

## v5.8.1+snap2

Supply-chain integrity for release artifacts.

Every release now includes three verification mechanisms so that users can confirm the snap they downloaded is authentic, untampered, and built by this repository's GitHub Actions workflow:

| Measure | Asset | What it proves |
|---------|-------|----------------|
| SHA256 checksum | `.sha256` | The file was not corrupted or modified after publication |
| Cosign keyless signature | `.cosign-bundle` | The file was signed by this repository's CI using Sigstore OIDC — no long-lived keys |
| SLSA provenance attestation | GitHub-native | The file was built by a specific workflow, from a specific commit, in this repository |

### Changes

- Build workflow generates SHA256 checksum, cosign keyless signature bundle, and SLSA provenance attestation for every release
- All three verification artifacts are uploaded alongside the snap as release assets
- README includes a Verification section with download and verification commands
- No secrets or long-lived keys required — cosign uses GitHub's OIDC identity, attestations use the built-in workflow token

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
