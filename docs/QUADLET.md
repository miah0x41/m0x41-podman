# Quadlet (Systemd Integration)

_Quadlet_ is _Podman_'s native mechanism for running containers as systemd services. Users write declarative `.container`, `.volume`, `.network`, and `.kube` definition files. When systemd reloads, it calls the _Quadlet_ generator binary, which reads those definitions and produces complete `.service` unit files.

This snap bundles the `quadlet` binary and systemd generators. The snap's install hook registers them with the host's systemd so that Quadlet works immediately after installation.

## How the Snap Supports Quadlet

Three things must be in place for Quadlet to work:

1. **systemd must discover the generators** — the install hook symlinks them from the snap into `/usr/lib/systemd/`
2. **Generated units must find `podman`** — the compiled-in path is `/usr/local/bin/podman`; the install hook creates a shim there
3. **The shim must set up the snap's environment** — `PATH`, `LD_LIBRARY_PATH`, and container config paths

All three are handled automatically by the snap's install hook (`snap/hooks/install`).

## Shim vs Wrapper

The snap has two entry points for _Podman_:

| Entry Point | Path | When Used | Messages |
|-------------|------|-----------|----------|
| **Wrapper** | `snap run m0x41-podman` | Interactive shell use via `m0x41-podman` command | Hello message, dependency warnings |
| **Shim** | `/usr/local/bin/podman` | systemd units, scripts, `podman` on PATH | None — silent, minimal |

Both set the same core environment (`PATH`, `LD_LIBRARY_PATH`, `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`). The shim deliberately omits the wrapper's hello message, dependency detection, and marker file logic because:

- systemd would capture those messages as service output
- Marker files would be created as root in unexpected locations
- The overhead would apply to every service start/stop/restart

## Files Created by the Install Hook

| File | Type | Purpose |
|------|------|---------|
| `/usr/local/bin/podman` | Script | Shim that sets snap environment and execs `podman` |
| `/usr/lib/systemd/system-generators/podman-system-generator` | Symlink | Rootful Quadlet generator |
| `/usr/lib/systemd/user-generators/podman-user-generator` | Symlink | Rootless Quadlet generator |
| `/usr/lib/systemd/{system,user}/podman.socket` | Symlink | Podman API socket unit |
| `/usr/lib/systemd/{system,user}/podman.service` | Script | Podman API service using the shim |
| `/usr/lib/systemd/{system,user}/podman-auto-update.service` | Script | Auto-update service using the shim |
| `/usr/lib/systemd/{system,user}/podman-auto-update.timer` | Symlink | Daily auto-update timer |
| `/usr/lib/systemd/{system,user}/podman-restart.service` | Script | Restart-policy service using the shim |
| `/usr/lib/systemd/system/podman-clean-transient.service` | Script | Transient data cleanup using the shim |
| `/usr/local/share/man/man{1,5}/podman*` | Symlinks | Man pages for commands (`man1`) and config formats (`man5`) |
| `/etc/containers/policy.json` | Copy | Image signature policy (only if not already present) |

The remove hook (`snap/hooks/remove`) cleans up all of these except `policy.json` (which may have been customised).

## Quick Start

### Rootful

```bash
# Create a container definition
sudo mkdir -p /etc/containers/systemd
sudo tee /etc/containers/systemd/my-app.container <<EOF
[Container]
Image=docker.io/library/nginx
PublishPort=8080:80

[Install]
WantedBy=default.target
EOF

# Reload and start
sudo systemctl daemon-reload
sudo systemctl start my-app.service
sudo systemctl status my-app.service
```

### Rootless

```bash
# Create a container definition
mkdir -p ~/.config/containers/systemd
cat > ~/.config/containers/systemd/my-app.container <<EOF
[Container]
Image=docker.io/library/nginx
PublishPort=8080:80

[Install]
WantedBy=default.target
EOF

# Reload and start (user session)
systemctl --user daemon-reload
systemctl --user start my-app.service
systemctl --user status my-app.service
```

## File Locations

| Scope | Definition Files | Generated Units |
|-------|-----------------|-----------------|
| Rootful | `/etc/containers/systemd/` | `/run/systemd/generator/` |
| Rootless (user) | `~/.config/containers/systemd/` | `$XDG_RUNTIME_DIR/systemd/generator/` |

## Limitations

- **Compiled-in path**: The `quadlet` generator embeds `/usr/local/bin/podman` in generated `ExecStart=` lines. This is a build-time constant. The shim must exist at that path for generated units to work.
- **`snap run` not used**: systemd calls the shim directly — it does not go through `snap run`. The shim replicates the wrapper's environment setup to compensate.
- **Rootless in LXD containers**: Rootless Quadlet requires a functioning D-Bus user session and `loginctl enable-linger`. In LXD containers, this may not work reliably (same limitation as rootless _Podman_ generally).
- **Host dependencies must be installed before reboot**: The wrapper's interactive dependency detection (see [WRAPPER.md](WRAPPER.md)) does not run when systemd starts Quadlet services at boot. If host dependencies like `uidmap` (`newuidmap`/`newgidmap`) or `dbus-user-session` are missing, all rootless Quadlet services will fail on boot with `exec: "newuidmap": executable file not found in $PATH`. Dependent services cascade-fail because the network unit cannot start. Install host dependencies (`sudo apt install uidmap dbus-user-session` on Debian/Ubuntu, `sudo dnf install shadow-utils dbus-daemon` on Fedora/CentOS) before enabling Quadlet services for boot.
- **`podman generate systemd` is deprecated**: This command is deprecated upstream in favour of Quadlet and will receive only urgent bug fixes. The snap's `PODMAN_BINARY` patch makes it functional (generated units reference the shim, not revision-specific paths), but Quadlet `.container` files remain the recommended approach.

## Uninstallation

Running `snap remove m0x41-podman` triggers the remove hook, which:

1. Warns if active Quadlet-generated services are detected
2. Removes the `/usr/local/bin/podman` shim (only if it contains the snap's marker comment)
3. Removes the generator symlinks (only if they point to this snap)
4. Removes all systemd units (only if they reference this snap's shim or symlink to it)
5. Removes man page symlinks (only if they point to this snap)
6. Runs `systemctl daemon-reload`

The remove hook does **not** delete `/etc/containers/policy.json` (may be user-customised or used by other tools) or any user-created `.container`/`.volume`/`.network` definition files.

## Testing

Quadlet functionality is tested in tier 5 of the test suite.

### Running Quadlet Tests

```bash
# Single distro (includes BATS/Go if available)
/usr/bin/sg lxd -c "./scripts/03_test_launch.sh tier5"

# Multi-distro (custom tests only, BATS/Go gated out)
/usr/bin/sg lxd -c "./scripts/06_test_multi_distro.sh"
```

### Test Sub-Tiers

| Sub-Tier | Tests | What It Validates |
|----------|-------|-------------------|
| 5a | 24 | Install hook artefacts: shim, generators, policy.json, wrappers, no-ldconfig-poisoning, systemd units (system + user), man pages |
| 5b | 3 | Quadlet dry-run: valid unit generation, correct ExecStart path |
| 5c | 2 | Live rootful Quadlet: systemd service starts and runs |
| 5d | 2 | Live rootless Quadlet: systemd user service starts and runs |
| 5e | 73 | Upstream BATS: `251-system-service` (19), `270-socket-activation` (3), `252-254` quadlet (51). Gated on BATS + Podman source |
| 5f | ~160 | Go e2e quadlet tests (gated on Go + Podman source) |

### Test Results

Tested 2026-03-25.

**Single distro (Ubuntu 24.04):** Tier 5 custom tests (5a-5d) 20/20 pass. BATS (5e) 68/73 — 5 failures in `252-quadlet.bats` (snap config conflicts + missing `htpasswd`). `251-system-service` (19/19) and `270-socket-activation` (3/3) pass fully.

**Multi-distro:** Tiers 1-3 + tier 5 custom tests.

| Distro | Tier 1 (7) | Tier 2 (8) | Tier 3 (6) | Tier 5 (20) |
|--------|------------|------------|------------|-------------|
| Ubuntu 22.04 | 7/7 | 8/8 | 6/6 | 20/20 |
| Ubuntu 24.04 | 7/7 | 8/8 | 6/6 | 20/20 |
| Debian 12 | 7/7 | 8/8 | 6/6 | 20/20 |
| CentOS 9 | 7/7 | 8/8 | 6/6 | 19/20 |
| Fedora 43 | 5/7 | 1/8 | 6/6 | 18/20 |

CentOS 9 and Fedora 43 tier 5 failures are rootless Quadlet tests — same underlying `newuidmap` setuid / `dbus-user-session` limitation in LXD containers that affects tier 2. Rootful Quadlet and socket unit installation pass on all distros.
