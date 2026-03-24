# Wrapper Script

The snap entry point is `bin/podman-wrapper`, not the _Podman_ binary directly. The wrapper performs three functions: environment setup, first-run guidance, and dependency detection. This document covers the wrapper's behaviour, the messages users will see, and how the dependency detection is tested.

## What the Wrapper Does

### 1. Environment Setup

The wrapper prepends the snap's binary and library directories to `PATH` and `LD_LIBRARY_PATH` so that _Podman_ and its child processes can find bundled components (`netavark`, `aardvark-dns`, `conmon`, `crun`, `libyajl`, `libgpgme`, etc.). It then exec's the real `podman` binary.

### 2. First-Run Hello Message

On the first _rootless_ invocation, the wrapper prints a welcome message to `stderr`:

```bash
  Welcome to m0x41-podman (Podman v5.8.1)

  Tip: alias as 'podman' for convenience:
    sudo snap alias m0x41-podman podman
```

- The alias tip is suppressed if `/snap/bin/podman` already symlinks to `m0x41-podman` (i.e. the snap alias is set) or if `/usr/local/bin/podman` exists with the snap's marker comment (i.e. the install hook's shim is in place). Since the install hook always creates the shim, the alias tip is effectively never shown after a normal installation.
- The message is shown once. A marker file at `~/.local/share/m0x41-podman/.hello` prevents it from appearing again.
- Root invocations never see this message.

**Note:** The wrapper is the entry point for `snap run m0x41-podman` (interactive use). The `/usr/local/bin/podman` shim created by the install hook is a separate, minimal entry point used by systemd and scripts. See [QUADLET.md](QUADLET.md) for details on the shim.

### 3. Dependency Detection

The snap cannot bundle certain host dependencies that require `setuid` bits, system services, or shared libraries loaded by processes outside the snap's control. On each _rootless_ invocation, the wrapper checks for these and prints a warning if any are missing:

```bash
  WARNING: missing host dependencies: newuidmap newgidmap dbus-user-session

  Fix: sudo apt install dbus-user-session uidmap

  To suppress this warning:
    mkdir -p ~/.local/share/m0x41-podman && echo x1 > ~/.local/share/m0x41-podman/.deps-ok
```

The checks are:

| Check | What It Detects | Why It Cannot Be Bundled |
|-------|-----------------|--------------------------|
| `command -v newuidmap` | `uidmap` package missing | Requires setuid bit — stripped during snap packing |
| `command -v newgidmap` | `uidmap` package missing | Same as above |
| `dbus-send --session` | `dbus-user-session` missing or no session bus | Requires a running system service |
| `/usr/sbin/ldconfig -p \| grep libgpg-error` | `libgpg-error` library missing | Loaded by processes outside the snap's `LD_LIBRARY_PATH` |

The install command adapts to the distro:

| Distro | Package Manager | Packages |
|--------|-----------------|----------|
| Ubuntu / Debian | `apt` | `uidmap`, `dbus-user-session`, `libgpg-error0` |
| Fedora / CentOS / RHEL | `dnf` | `shadow-utils`, `dbus-daemon`, `libgpg-error` |

## Marker Files

The wrapper uses two marker files in `~/.local/share/m0x41-podman/`:

| File | Purpose | Created When | Effect |
|------|---------|-------------|--------|
| `.hello` | Prevents hello message repeating | First rootless run | Hello message never shown again |
| `.deps-ok` | Skips dependency checks | All deps present, or manually by user | Contains snap revision; re-checks after snap upgrade |

### Automatic Behaviour

- If all dependencies are present on the first check, `.deps-ok` is created automatically and the user sees nothing.
- If dependencies are missing, the warning repeats on every invocation until the user either installs the packages or manually creates the marker.
- After a snap upgrade (new `SNAP_REVISION`), the marker is invalidated and dependencies are re-checked once.

### Manual Suppression

Users who cannot or choose not to install the missing packages can suppress the warning:

```bash
mkdir -p ~/.local/share/m0x41-podman && echo x1 > ~/.local/share/m0x41-podman/.deps-ok
```

The exact command is printed as part of the warning message. The snap revision (`x1` for `--dangerous` installs) must match the installed snap.

## Root Behaviour

The entire first-run and dependency check block is skipped when running as root (`uid 0`). _Rootful_ _Podman_ does not need `uidmap` or `dbus-user-session`, and `libgpg-error` is checked only in _rootless_ context to avoid false positives when the library is present but `ldconfig` isn't in the non-root user's PATH.

## Testing

The wrapper's behaviour is validated by a dedicated multi-distro test suite that runs across Ubuntu 22.04, Ubuntu 24.04, Debian 12, CentOS 9 Stream, and Fedora 42.

### Running Wrapper Tests

```bash
# All distros in parallel
/usr/bin/sg lxd -c "./scripts/08_wrapper_test_launch.sh"

# With cleanup (delete containers after)
/usr/bin/sg lxd -c "./scripts/08_wrapper_test_launch.sh --cleanup"

# Re-run on an existing container
/usr/bin/sg lxd -c "lxc exec snap-wtest-22-debian-12 -- /root/10_wrapper_tests.sh"
```

### Test Scripts

| Script | Runs On | Purpose |
|--------|---------|---------|
| `08_wrapper_test_launch.sh` | Host | Parallel orchestrator — launches five distro containers and collects results |
| `09_wrapper_test_setup.sh` | Container | Minimal setup — installs snap without rootless dependencies to create a "missing deps" scenario |
| `10_wrapper_tests.sh` | Container | 19-test suite across 6 phases |

### Test Phases

| Phase | Tests | What It Validates |
|-------|-------|-------------------|
| 1. Root invocation | 2 | No hello message, no dependency warning when running as root |
| 2. First rootless run | 6 | Hello message shown, alias tip shown, hello marker created, dependency warning with distro-specific install command and suppress instructions |
| 3. Second rootless run | 3 | Hello message not repeated, dependency warning persists, suppress instructions shown |
| 4. Manual suppression | 2 | Marker file silences dependency warning |
| 5. After installing deps | 3 | `newuidmap`/`newgidmap` and `libgpg-error` no longer reported missing, marker behaviour correct |
| 6. Alias tip suppression | 3 | Hello re-shown after marker reset, alias tip hidden when `/snap/bin/podman` symlink exists |

### Test Results

Tested 2026-03-24 on WSL2. All distros pass 19/19.

| Distro | Result |
|--------|--------|
| Ubuntu 22.04 | 19/19 pass |
| Ubuntu 24.04 | 19/19 pass |
| Debian 12 | 19/19 pass |
| CentOS 9 Stream | 19/19 pass |
| Fedora 42 | 19/19 pass |

### Test Environment Limitations

- **D-Bus session bus**: `dbus-send --session` always fails inside LXD containers when using `su -` because no logind session exists. The wrapper correctly detects this as a missing dependency. The phase 5 tests tolerate `dbus-user-session` remaining flagged in container environments — this is a test infrastructure limitation, not a wrapper bug.
- **`snap run` stderr**: On Ubuntu, `snap run` intercepts the wrapper's stderr output, making it invisible to the calling process. The tests invoke the wrapper binary directly with `SNAP`, `SNAP_VERSION`, and `SNAP_REVISION` environment variables set to bypass this. The wrapper logic is identical in both paths.
- **`ldconfig` PATH**: On Debian, `/usr/sbin` is not in non-root users' default PATH. The wrapper uses the absolute path `/usr/sbin/ldconfig` to ensure the `libgpg-error` check works on all distros.

### Container Naming

Wrapper test containers use the prefix `snap-wtest-22-` (e.g. `snap-wtest-22-debian-12`) to distinguish them from the functional test containers (`snap-test-22-*`).
