# User Guide: Snap vs Native _Podman_

This document covers how `m0x41-podman` differs from a native _Podman_ install. If you have used _Podman_ before, read this to understand what the snap changes, what it does not support, and how to work around the differences.

## Host Dependencies

The snap bundles _Podman_ and all its runtime components, but a few things **cannot** be bundled and must exist on the host.

### Rootless Mode (All Distros)

| Dependency | Why It Cannot Be Bundled |
|------------|--------------------------|
| `newuidmap` / `newgidmap` (`uidmap`) | Require the setuid bit, which snap packing strips |
| `dbus-user-session` | Requires a running system D-Bus service |

Without these, rootless containers fail with _"Operation not permitted"_. Ubuntu Desktop includes both by default; server, minimal, and container images do not.

| Distro | Install Command |
|--------|-----------------|
| Ubuntu / Debian | `sudo apt install uidmap dbus-user-session` |
| Fedora / CentOS / RHEL | `sudo dnf install shadow-utils dbus-daemon` |

The wrapper detects missing dependencies on first run and prints distro-specific install instructions. See [WRAPPER.md](WRAPPER.md) for details on the detection mechanism and how to suppress warnings.

### Rootful Mode (Non-Ubuntu Distros)

`netavark` (the container network backend) calls `iptables` as a child process of `conmon`. Child processes do not inherit the snap's `PATH`, so `iptables` must be available at the system level. Ubuntu ships it by default; other distros do not.

| Distro | Install Command |
|--------|-----------------|
| Debian 12 | `sudo apt install iptables` |
| CentOS 9 Stream / Fedora 42 | `sudo dnf install iptables-nft` |

## Networking: `slirp4netns` Instead of `pasta`

Native _Podman_ v5.x defaults to `pasta` (`passt`) for rootless networking. `pasta` is faster and supports features like port ranges in `--publish` and improved IPv6 handling.

This snap uses `slirp4netns` instead, because `pasta` is not available on the `core22` (Ubuntu 22.04) base. This is configured in the snap's `containers.conf`:

```ini
[network]
default_rootless_network_cmd = "slirp4netns"
```

**What this means in practice:**

- Rootless networking works, but may be slower than a native install using `pasta`
- `--network pasta` will fail — the binary is not bundled
- The 86 `pasta`-specific upstream tests are skipped (not failures)
- Rootful networking is unaffected — it uses `netavark` with bridge networking in both cases

## Configuration

### The Normal Config Chain Is Replaced

This is the most significant architectural difference. Native _Podman_ reads configuration from a cascade of files:

```
~/.config/containers/containers.conf    (user)
/etc/containers/containers.conf         (system)
built-in defaults                       (compiled)
```

The snap **replaces this chain** by setting three environment variables that point to its own bundled config files:

| Variable | Points To |
|----------|-----------|
| `CONTAINERS_CONF` | `/snap/m0x41-podman/current/etc/containers/containers.conf` |
| `CONTAINERS_REGISTRIES_CONF` | `/snap/m0x41-podman/current/etc/containers/registries.conf` |
| `CONTAINERS_STORAGE_CONF` | `/snap/m0x41-podman/current/etc/containers/storage.conf` |

This is **required** because the bundled config contains absolute paths to snap-internal binaries (`crun`, `conmon`, `netavark`, `fuse-overlayfs`, `slirp4netns`). Without it, _Podman_ would not find its runtime components.

**The consequence:** any `containers.conf`, `storage.conf`, or `registries.conf` you place in the standard locations (`~/.config/containers/`, `/etc/containers/`) will be **ignored**.

### How to Customise `containers.conf`

_Podman_ supports `CONTAINERS_CONF_OVERRIDE`, which is loaded **last** — even when `CONTAINERS_CONF` is set. Create an overrides file:

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/overrides.conf <<EOF
[engine]
events_logger = "journald"
EOF
```

Then export the variable (add to `~/.bashrc` or equivalent):

```bash
export CONTAINERS_CONF_OVERRIDE="$HOME/.config/containers/overrides.conf"
```

**Settings that are safe to override** include `cgroup_manager`, `events_logger`, `log_driver`, `log_size_max`, `env`, `init_path`, `infra_image`, and any setting that does not specify a path to a snap-bundled binary.

**Settings that must NOT be overridden** (changing these will break the snap):

| Setting | Reason |
|---------|--------|
| `helper_binaries_dir` | Locates `slirp4netns`, `netavark`, and other helpers |
| `conmon_path` | Path to the container monitor |
| `crun` runtime path | Path to the OCI runtime |
| `netavark_path` | Path to the network backend |
| `default_rootless_network_cmd` | Must be `slirp4netns` (snap does not bundle `pasta`) |

### No Override Mechanism for `storage.conf` or `registries.conf`

Unlike `containers.conf`, _Podman_ has no `CONTAINERS_STORAGE_CONF_OVERRIDE` or `CONTAINERS_REGISTRIES_CONF_OVERRIDE`. The snap's storage and registry configuration cannot be partially customised.

**Storage** is locked to:

```ini
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/snap/m0x41-podman/current/usr/bin/fuse-overlayfs"
```

Changing the storage driver or `mount_program` path would break rootless operation.

**Registries** default to:

```ini
unqualified-search-registries = ["docker.io", "quay.io"]
```

To add registries, mirrors, or configure registry authentication, you would need to override `CONTAINERS_REGISTRIES_CONF` to point to your own file. However, this is a complete replacement — you must include any settings from the snap's default that you want to keep.

### Event Logging

The snap sets `events_logger = "file"` rather than the native default of `journald`. This means `podman events` reads from a file rather than the systemd journal, and events will not appear in `journalctl`. Override this via `CONTAINERS_CONF_OVERRIDE` if you prefer journal-based logging.

### Image Signature Policy

The snap ships a permissive `policy.json`:

```json
{"default": [{"type": "insecureAcceptAnything"}]}
```

This is installed to `/etc/containers/policy.json` only if the file does not already exist. To enforce stricter signature verification, edit `/etc/containers/policy.json` directly — the snap reads the host copy.

## The Wrapper and Shim

The snap has two entry points for running `podman`. Understanding the difference matters if you use systemd services, scripts, or automation.

### Wrapper (`snap run m0x41-podman` or `m0x41-podman`)

This is the interactive entry point. It:

1. Sets `PATH` and `LD_LIBRARY_PATH` to find snap-bundled binaries and libraries
2. Shows a one-time welcome message on first rootless invocation
3. Detects missing host dependencies and prints distro-specific install instructions
4. Runs `podman`

### Shim (`/usr/local/bin/podman`)

Created by the install hook. This is the entry point for systemd units, Quadlet-generated services, and scripts. It:

1. Sets the same `PATH`, `LD_LIBRARY_PATH`, and config environment variables
2. Runs `podman`

The shim is intentionally silent — no messages, no dependency checks — because systemd would capture that output and it would add latency to every service start.

Both entry points set identical core environment. The only difference is the user-facing messages. See [WRAPPER.md](WRAPPER.md) for the full message logic, marker files, and testing.

## Systemd Integration

### Quadlet Works

Quadlet (`.container`, `.volume`, `.network`, `.kube` files) is fully supported. The install hook registers systemd generators so that Quadlet works immediately after installation. See [QUADLET.md](QUADLET.md) for details, file locations, and examples.

### `podman generate systemd` Is Not Supported

`podman generate systemd` is deprecated upstream and hardcodes revision-specific snap paths (e.g. `/snap/m0x41-podman/x1/usr/bin/podman`) that break on every `snap refresh`. Use Quadlet `.container` files instead.

### Podman API Socket

The install hook registers `podman.socket` and `podman.service` unit files. Enable the socket with:

```bash
systemctl --user enable --now podman.socket
```

The service unit uses the shim at `/usr/local/bin/podman`, not the snap binary directly — this survives snap refresh.

## Source Modification

The snap applies one patch to the upstream _Podman_ source at build time. _Podman_ creates transient systemd units for container healthchecks and embeds its own binary path in them. In the snap, this path resolves to the raw binary inside the snap filesystem, which lacks the library path setup needed to find bundled libraries. The patch adds three lines to `libpod/healthcheck_linux.go` that propagate `LD_LIBRARY_PATH` to the transient unit — mirroring how _Podman_ already propagates `PATH`. Without this patch, container healthchecks fail silently. See [COMPONENTS.md](COMPONENTS.md#source-modifications) for details and [HEALTHCHECK_ISSUES.md](investigations/HEALTHCHECK_ISSUES.md) for the full analysis.

## Unsupported Features

### `podman machine`

`podman machine` creates and manages VMs via QEMU. The snap does not bundle QEMU or the machine provider. If you need `podman machine` (common on macOS or WSL2 workflows), use a native _Podman_ install.

### `podman compose`

`podman-compose` is a separate project not included in the snap. You can install it independently (`pip install podman-compose`) and point it at the snap's `podman` binary. Docker Compose can also work with the Podman API socket.

### Checkpoint and Restore

`podman container checkpoint` and `podman container restore` require CRIU, which is not bundled.

### SELinux

The snap does not include SELinux policy modules. Tests that require SELinux are skipped.

### Remote Mode

`podman --remote` and `podman system connection` are not tested with this snap.

## Architecture and Platform

| Constraint | Detail |
|------------|--------|
| **Architecture** | `amd64` only — no `arm64` / `aarch64` |
| **glibc floor** | >= 2.34 (pre-built `netavark` / `aardvark-dns` require this) |
| **Base** | `core22` (Ubuntu 22.04, `glibc` 2.35) |
| **snapd** | Required on the host |

Distros older than ~2021 (e.g. Ubuntu 20.04 with `glibc` 2.31, Debian 10) will not work.

## Man Pages

The snap bundles _Podman_ man pages. The install hook symlinks them into `/usr/local/share/man/` so they are discoverable by `man`:

```bash
man podman              # main overview
man podman-run          # command reference
man podman-build        # command reference
man containers.conf     # configuration file format (man5)
```

Command pages (`man1`) and configuration file format pages (`man5`) from the upstream build are included. If `man-db` is installed on the host, `man podman` works immediately after `snap install`. The man pages are removed cleanly on `snap remove`.

## Install Hook Side Effects

The install hook runs as root on `snap install` and `snap refresh`. It creates the following on the host filesystem:

| Path | Purpose |
|------|---------|
| `/usr/local/bin/podman` | Shim script (entry point for systemd and PATH) |
| `/usr/lib/systemd/system-generators/podman-system-generator` | Symlink to snap's Quadlet generator (rootful) |
| `/usr/lib/systemd/user-generators/podman-user-generator` | Symlink to snap's Quadlet generator (rootless) |
| `/usr/lib/systemd/system/podman.socket` | Symlink to snap's socket unit (rootful) |
| `/usr/lib/systemd/system/podman.service` | API service using the shim (rootful) |
| `/usr/lib/systemd/system/podman-auto-update.service` | Auto-update service using the shim |
| `/usr/lib/systemd/system/podman-auto-update.timer` | Symlink to snap's daily timer |
| `/usr/lib/systemd/system/podman-restart.service` | Restart-policy service using the shim |
| `/usr/lib/systemd/system/podman-clean-transient.service` | Transient data cleanup using the shim |
| `/usr/lib/systemd/user/podman.socket` | Symlink to snap's socket unit (rootless) |
| `/usr/lib/systemd/user/podman.service` | API service using the shim (rootless) |
| `/usr/lib/systemd/user/podman-auto-update.service` | Auto-update service using the shim (rootless) |
| `/usr/lib/systemd/user/podman-auto-update.timer` | Symlink to snap's daily timer (rootless) |
| `/usr/lib/systemd/user/podman-restart.service` | Restart-policy service using the shim (rootless) |
| `/usr/local/share/man/man1/podman*` | Symlinks to snap's command man pages |
| `/usr/local/share/man/man5/podman*` | Symlinks to snap's config file format man pages |
| `/etc/containers/policy.json` | Image signature policy (only if absent) |

All hook-created files are removed by the remove hook (`snap remove`) using marker-based ownership checks. The remove hook preserves `/etc/containers/policy.json` since it may be used by other tools.

## Replacing a Native _Podman_ Install

If you are replacing a distribution-packaged _Podman_ (e.g. `apt install podman`) with this snap, **purge the native package first**. A simple `apt remove` leaves configuration files, systemd enablement symlinks, and `ld.so.conf.d` entries behind. These artefacts cause conflicts:

- **Enablement symlinks** at `/etc/systemd/system/*.target.wants/podman*` point to unit files that no longer exist after removal. systemd logs warnings for each dangling symlink at every boot and `daemon-reload`.
- **`/etc/containers/`** retains `libpod.conf`, `registries.conf`, and `policy.json` from the native package. These are harmless (the snap uses its own config via environment variables) but clutter the filesystem.
- **`/etc/ld.so.conf.d/podman-snap.conf`** may exist from a previous snap revision that registered snap library paths system-wide. This is no longer needed and should be deleted.

### Recommended: Purge Before Installing the Snap

```bash
# Stop any running podman services
sudo systemctl stop podman.socket podman.service 2>/dev/null
systemctl --user stop podman.socket podman.service 2>/dev/null

# Purge the native package (removes binaries AND config files)
sudo apt purge podman 2>/dev/null
# Or on Fedora/CentOS:
# sudo dnf remove podman

# Clean up any stale ldconfig entries
sudo rm -f /etc/ld.so.conf.d/podman-snap.conf*
sudo ldconfig

# Install the snap
sudo snap install m0x41-podman --dangerous --classic
```

### Alternative: Selective Cleanup

If you cannot purge (e.g. other packages depend on `podman`), disable the stale systemd units manually:

```bash
# Disable stale system-level units
sudo systemctl disable podman.service podman.socket \
    podman-auto-update.service podman-auto-update.timer \
    podman-restart.service podman-clean-transient.service 2>/dev/null

# Remove stale ldconfig entries
sudo rm -f /etc/ld.so.conf.d/podman-snap.conf*
sudo ldconfig
```

The snap's install hook detects stale artefacts and prints a warning with cleanup instructions if any are found.

### What the Snap Does Not Touch

The snap does not remove or modify files from the native package. Specifically:

- `/etc/containers/libpod.conf` — stale config from native podman v4.x; harmless
- `/etc/containers/registries.conf` — the snap uses its own copy via `CONTAINERS_REGISTRIES_CONF`
- `/etc/containers/policy.json` — the snap only writes this if absent
- Container storage at `/var/lib/containers/` — rootful containers from the native install remain accessible

## Snap Refresh Behaviour

When `snap refresh` runs:

1. The `current` symlink is updated to the new revision
2. The install hook re-runs, updating the shim, generator symlinks, and man page symlinks
3. The wrapper's dependency marker (`.deps-ok`) is invalidated, triggering a one-time re-check
4. Running containers are **not** migrated or restarted

Any hardcoded revision paths (e.g. from `podman generate systemd` output or manual scripts referencing `/snap/m0x41-podman/x1/...`) will break. The shim and Quadlet-generated units use the `current` symlink and are unaffected.

## Quick Reference

| Aspect | Native _Podman_ v5.8.1 | `m0x41-podman` Snap |
|--------|------------------------|---------------------|
| Rootless networking | `pasta` (default) | `slirp4netns` |
| Config loading | Cascade (`~/.config/`, `/etc/`) | Snap-bundled only; use `CONTAINERS_CONF_OVERRIDE` |
| Storage config | User-customisable | Locked to `overlay` + `fuse-overlayfs` |
| Registry config | User-customisable | Locked to `docker.io` + `quay.io` (replaceable) |
| Event logging | `journald` (default) | `file` (overridable) |
| Quadlet | Supported | Supported |
| `generate systemd` | Deprecated but works | Not supported (breaks on refresh) |
| `podman machine` | Supported | Not supported |
| `podman compose` | Separate install | Separate install |
| Checkpoint/restore | Supported (with CRIU) | Not supported |
| Architecture | Multi-arch | `amd64` only |
| Man pages | Installed system-wide | Symlinked from snap into `/usr/local/share/man/` |
| Host deps (rootless) | None (all bundled) | `uidmap`, `dbus-user-session` |
| Host deps (non-Ubuntu) | None | `iptables` |
