# Classic Confinement Request for m0x41-podman

## Request

- **name**: m0x41-podman
- **description**: Podman v5.8.1 container engine with all runtime dependencies bundled (crun, conmon, netavark, aardvark-dns, fuse-overlayfs, slirp4netns, catatonit). Supports _rootless_ and _rootful_ operation, including _Quadlet_ (systemd integration). Built on core22.
- **snapcraft**: https://github.com/miah0x41/m0x41-podman/blob/main/snapcraft.yaml
- **upstream**: https://github.com/containers/podman
- **upstream-relation**: No upstream affiliation, I'm an independent packager. This snap packages unmodified upstream sources.
- **supported-category**: Development tool / container runtime.

_Podman_ is a daemonless container engine used for developing, managing, and running OCI containers. Analogous to _Docker_. It requires host filesystem access for setuid binaries, library path propagation, and systemd generator registration, none of which are achievable under strict confinement.

[x] I understand that strict confinement is generally preferred over classic.

[x] I've tried the [existing interfaces](https://snapcraft.io/docs/supported-interfaces) to make the snap to work under strict confinement.

## Rationale

As the upstream project is mature and popular to which I have no formal relationship, I have no means to adapt it to meet the confines of Snap, therefore this is more of an attempt utilise Snap features to enable _Podman_ to work within these constraints.

Strict confinement's mount namespace replaces `/usr/bin` with the base snap's copy, which breaks both rootless and rootful container operation through four fundamental constraints:

### 1. setuid `newuidmap`/`newgidmap` unreachable

The host's setuid binaries (from the `uidmap` package) are hidden by the mount namespace. Staging them inside the snap does not work: `snapcraft` strips setuid bits during packing, `squashfs` mounts with `nosuid`, and file capabilities are also stripped. Without these binaries, rootless user namespace creation fails outright.

### 2. `netavark` path resolution failure

_Podman_ discovers its network backend (`netavark`) via `helper_binaries_dir`, not the `netavark_path` configuration key. Under strict confinement the bundled binary cannot be found, so all container networking fails.

### 3. `LD_LIBRARY_PATH` lost across process boundaries

The snap wrapper sets `LD_LIBRARY_PATH` for _Podman_, but when _Podman_ spawns `conmon`, which then spawns `crun`, the library path is not inherited. Bundled libraries such as `libyajl` (required by `crun`) are not found, causing every `podman run` to fail with an OCI runtime error.

### 4. `policy.json` path cannot be changed

_Podman_ hardcodes two filesystem paths for `policy.json` and provides no environment variable override. Under strict confinement the snap cannot place the file at either expected location.

> These four constraints block container execution in both _rootless_ and _rootful_ modes. No combination of existing `snapd` interfaces (`system-files`, `personal-files`, layouts, `snapcraft-preload`) resolves all four simultaneously. The `system-files` interface cannot grant access to setuid binaries. Layouts cannot inject files into paths owned by the base snap. The library path propagation issue occurs across process boundaries that `snapd` does not appear to control.

### 5. Snap runtime directory not created for non-interactive sessions

`su -` does not trigger a `logind` session, so `snapd` never creates `/run/user/<uid>/snap.<snap-name>`, breaking _rootless_ operation when invoked via `su` or `sudo -u`.

### 6. Install hook cannot modify the host

Classic confinement enables the snap's install hook to register `systemd` generators for _Quadlet_ (`systemd` container integration) and place a `podman` shim on PATH at `/usr/local/bin/podman`. These operations write to `/usr/lib/systemd/` and `/usr/local/bin/` — both prohibited under strict confinement. Without them, _Quadlet_ does not work and users must invoke the snap by its full name rather than `podman`.

One of the key changes to v5 of _Podman_ is the ability to orchestrate pods using _Quadlets_ relative to v4 (currently in Ubuntu 24.04).

## Interfaces Evaluated

| Interface | Why It Is Insufficient |
|-----------|----------------------|
| `docker-support` | Super-privileged and explicitly restricted to the Docker project ("may only be established with the Docker project"). Not available for independent snaps |
| `userns` | Permits user namespace creation via `unshare()`, but does not make the host's setuid `newuidmap`/`newgidmap` binaries visible. _Podman_ invokes these as external binaries — the mount namespace hides them regardless of `userns` capability |
| `mount-control` | Explicitly excludes `overlayfs` from supported filesystem types. Container storage requires overlay mounts at arbitrary paths |
| `fuse-support` | Only permits FUSE mounts within snap-specific writable directories (`SNAP_DATA`, `SNAP_USER_DATA`). Container storage mounts at `/var/lib/containers/storage/overlay/`, which is outside these directories |
| `firewall-control` | Addresses firewall rule management but does not solve `iptables` binary discovery. `netavark` invokes `iptables` as a child process of `conmon`, which does not inherit the snap's `PATH` |
| `system-files` | Can expose specific files but cannot make setuid binaries executable across the mount namespace boundary. Does not solve cross-process `LD_LIBRARY_PATH` propagation |
| `personal-files` | Irrelevant — all constraints involve system paths (`/usr/bin`, `/usr/lib/systemd/`, `/etc/`), not the user's home directory |
| Layouts | Cannot override paths owned by the base snap (`/usr/bin`). Cannot inject setuid binaries or register systemd generators |
| `snapcraft-preload` | Does not address setuid bit stripping, cross-process `LD_LIBRARY_PATH` loss, or the mount namespace hiding host binaries |

## Mitigations

The snap takes care to minimise its host footprint and clean up after itself:

- **Install hook is idempotent** — safe to run on install and refresh. Creates a `/usr/local/bin/podman` shim (marked with an identifying comment), symlinks systemd generators, installs corrected systemd units (auto-update, restart, API socket/service), symlinks man pages, and copies `policy.json` only if not already present. Detects stale artefacts from a previous native podman installation and warns the user.
- **Remove hook cleans up** — removes the shim (only if it contains the snap's marker comment), removes generator symlinks (only if they point to this snap), removes all installed systemd units (only if they reference the shim), removes man page symlinks, and reloads systemd. Does not remove `policy.json` (may be user-customised or used by other tools).
- **No background daemon** — _Podman_ is daemonless. The snap runs only when the user invokes it.
- **Cross-distro tested** — validated across Ubuntu 22.04, Ubuntu 24.04, Debian 12, CentOS 9 Stream, and Fedora 43 in both rootless and rootful modes with a 5-tier automated test suite.
