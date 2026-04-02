# Bundled Components

The snap packages _Podman_ alongside its required runtime dependencies. No upstream source code is modified — components are either built from unmodified source or included as unmodified pre-built binaries.

## Component Table

| Component | Version | License | SPDX | Upstream | How Bundled |
|-----------|---------|---------|------|----------|-------------|
| _Podman_ | v5.8.1 | Apache License 2.0 | `Apache-2.0` | [containers/podman](https://github.com/containers/podman) | Built from source (unmodified) |
| `crun` | 1.19.1 | GNU GPL v2 or later | `GPL-2.0-or-later` | [containers/crun](https://github.com/containers/crun) | Built from source (unmodified) |
| `netavark` | 1.14.1 | Apache License 2.0 | `Apache-2.0` | [containers/netavark](https://github.com/containers/netavark) | Pre-built binary from GitHub Releases |
| `aardvark-dns` | 1.14.0 | Apache License 2.0 | `Apache-2.0` | [containers/aardvark-dns](https://github.com/containers/aardvark-dns) | Pre-built binary from GitHub Releases |
| `conmon` | 2.0.25 (Ubuntu 22.04) | Apache License 2.0 | `Apache-2.0` | [containers/conmon](https://github.com/containers/conmon) | Ubuntu package via `stage-packages` — **known bug**: stderr data loss with large stdout ([conmon#236](https://github.com/containers/conmon/issues/236), fixed in v2.0.26) |
| `slirp4netns` | Ubuntu 22.04 | GNU GPL v2 | `GPL-2.0-only` | [rootless-containers/slirp4netns](https://github.com/rootless-containers/slirp4netns) | Ubuntu package via `stage-packages` |
| `fuse-overlayfs` | Ubuntu 22.04 | GNU GPL v2 or later | `GPL-2.0-or-later` | [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs) | Ubuntu package via `stage-packages` |
| `catatonit` | Ubuntu 22.04 | GNU GPL v2 | `GPL-2.0-only` | [openSUSE/catatonit](https://github.com/openSUSE/catatonit) | Ubuntu package via `stage-packages` |

### Build-Time Only (Not Included in Snap)

| Component | Version | License | SPDX | Upstream |
|-----------|---------|---------|------|----------|
| `Go` | 1.24.2 | BSD 3-Clause | `BSD-3-Clause` | [go.dev](https://go.dev/dl/) |

## Why Each Component Is Needed

| Component | Role |
|-----------|------|
| **_Podman_** | Container engine — the primary binary |
| **`crun`** | OCI runtime — executes containers. Ubuntu 22.04/24.04's packaged `crun` is too old for _Podman_ v5.8.1 |
| **`netavark`** | Container networking backend — sets up bridges, port forwarding, firewall rules |
| **`aardvark-dns`** | DNS server for container networks — resolves container names |
| **`conmon`** | Container monitor — holds stdio and manages container lifecycle after _Podman_ exits |
| **`slirp4netns`** | Rootless networking — provides network access without root privileges |
| **`fuse-overlayfs`** | Rootless storage — overlay filesystem in userspace for rootless containers |
| **`catatonit`** | Minimal init — PID 1 process for pods |

## Source Code Availability

This snap distributes GPL-licensed binaries. In accordance with the GNU GPL, source code for all GPL-licensed components is available from their upstream repositories linked above, at the exact versions listed in the component table.

The `snapcraft.yaml` at the root of this repository contains the complete build instructions, including the exact source tags, download URLs, and build commands used to produce the snap. Anyone can reproduce the build by running `snapcraft` with this file.

## Licensing of This Repository

The original work in this repository (shell scripts, `snapcraft.yaml`, configuration files, documentation) is licensed under the **Apache License 2.0** — see [LICENSE](../LICENSE).

The snap artifact produced by building this project contains a mixture of Apache-2.0 and GPL-2.0 licensed binaries, as detailed above. Distribution of the snap must comply with the licence terms of all bundled components.
