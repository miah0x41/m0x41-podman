# Bundled Components

The snap packages _Podman_ alongside its required runtime dependencies. Components are either built from source or included as pre-built binaries. Two upstream source modifications are applied — see [Source Modifications](#source-modifications) below.

## Component Table

| Component | Version | License | SPDX | Upstream | How Bundled |
|-----------|---------|---------|------|----------|-------------|
| _Podman_ | v5.8.1 | Apache License 2.0 | `Apache-2.0` | [containers/podman](https://github.com/containers/podman) | Built from source ([two patches](#source-modifications)) |
| `crun` | 1.19.1 | GNU GPL v2 or later | `GPL-2.0-or-later` | [containers/crun](https://github.com/containers/crun) | Built from source (unmodified) |
| `netavark` | 1.14.1 | Apache License 2.0 | `Apache-2.0` | [containers/netavark](https://github.com/containers/netavark) | Pre-built binary from GitHub Releases |
| `aardvark-dns` | 1.14.0 | Apache License 2.0 | `Apache-2.0` | [containers/aardvark-dns](https://github.com/containers/aardvark-dns) | Pre-built binary from GitHub Releases |
| `conmon` | 2.0.26 | Apache License 2.0 | `Apache-2.0` | [containers/conmon](https://github.com/containers/conmon) | Built from source (unmodified) — upgraded from Ubuntu 22.04's v2.0.25 to fix stderr data loss ([conmon#236](https://github.com/containers/conmon/issues/236)) |
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

## Source Modifications

Two patches are applied to the _Podman_ source at build time. Both patch files are in the `patches/` directory and are applied in the `override-build` step of `snapcraft.yaml`.

| Patch | Files | Change | Why |
|-------|-------|--------|-----|
| `healthcheck-ld-library-path.patch` | `libpod/healthcheck_linux.go` | Propagate `LD_LIBRARY_PATH` via `--setenv` when creating transient systemd healthcheck units | _Podman_ embeds its own binary path (via `/proc/self/exe`) in transient systemd units for container healthchecks. In the snap, this resolves to the raw binary inside the snap filesystem, bypassing the shim's `LD_LIBRARY_PATH` setup. Without the patch, healthcheck timers fail with `libgpgme.so.11: cannot open shared object file`. The patch adds three lines that mirror the existing `PATH` propagation, passing `LD_LIBRARY_PATH` to the transient unit via `systemd-run --setenv`. |
| `generate-systemd-binary-path.patch` | `pkg/systemd/generate/containers.go`, `pkg/systemd/generate/pods.go`, `pkg/domain/infra/abi/containers_runlabel.go` | Check `PODMAN_BINARY` env var and override the resolved binary path in text output | _Podman_ resolves its own binary path via `os.Executable()` and `os.Args[0]` and embeds it in `podman generate systemd` output and `runlabel --display` output. In the snap, this resolves to the raw binary inside the snap filesystem. The patch allows the wrapper/shim to set the shim path via `PODMAN_BINARY`, so generated units and display output reference `/usr/local/bin/podman`. |

The healthcheck patch follows the existing upstream code pattern (identical to how `PATH` is already propagated) and has no effect when `LD_LIBRARY_PATH` is unset. See [HEALTHCHECK_ISSUES.md](investigations/HEALTHCHECK_ISSUES.md) for the full root cause analysis and [PATCH_SECURITY_REVIEW.md](investigations/PATCH_SECURITY_REVIEW.md) for the security review.

The binary path patch affects text output only — it does not change which binary is executed. See [RCCA-GENERATE-SYSTEMD.md](investigations/RCCA-GENERATE-SYSTEMD.md) for the root cause analysis and [PATCH_SECURITY_REVIEW_BINARY_PATH.md](investigations/PATCH_SECURITY_REVIEW_BINARY_PATH.md) for the security review.

All other components (`crun`, `netavark`, `aardvark-dns`, `conmon`, etc.) are unmodified.

## Source Code Availability

This snap distributes GPL-licensed binaries. In accordance with the GNU GPL, source code for all GPL-licensed components is available from their upstream repositories linked above, at the exact versions listed in the component table.

The `snapcraft.yaml` at the root of this repository contains the complete build instructions, including the exact source tags, download URLs, build commands, and patches used to produce the snap. Anyone can reproduce the build by running `snapcraft` with this file.

## Licensing of This Repository

The original work in this repository (shell scripts, `snapcraft.yaml`, configuration files, documentation) is licensed under the **Apache License 2.0** — see [LICENSE](../LICENSE).

The snap artifact produced by building this project contains a mixture of Apache-2.0 and GPL-2.0 licensed binaries, as detailed above. Distribution of the snap must comply with the licence terms of all bundled components.
