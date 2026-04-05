# Healthcheck Transient Unit Issue

_Podman_ creates transient systemd timer and service units for container healthchecks. These units invoke the _Podman_ binary directly at its resolved path inside the snap, bypassing the shim and its `LD_LIBRARY_PATH` setup. The result is that healthcheck units fail with `libgpgme.so.11: cannot open shared object file`.

This document analyses the root cause, evaluates potential solutions, and recommends a fix.

## Symptom

After starting containers with healthchecks, `journalctl --user` shows repeated failures from transient units:

```
/snap/m0x41-podman/x1/usr/bin/podman: error while loading shared libraries:
  libgpgme.so.11: cannot open shared object file: No such file or directory
```

The transient timer descriptions confirm the raw snap path:

```
systemctl --user list-units --type=timer
  79b22b...timer  loaded active waiting  /snap/m0x41-podman/x1/usr/bin/podman healthcheck run 79b22b...
```

The containers themselves run correctly — only the healthcheck timers are affected.

## Root Cause

### How _Podman_ Creates Healthcheck Timers

In `libpod/healthcheck_linux.go`, the unexported function `createTimer()` constructs a `systemd-run` command to create a transient timer and service:

```go
podman, err := os.Executable()   // reads /proc/self/exe
// ...
path := os.Getenv("PATH")
if path != "" {
    cmd = append(cmd, "--setenv=PATH="+path)
}
cmd = append(cmd, "--unit", hcUnitName, ..., podman)
```

`os.Executable()` calls `readlink("/proc/self/exe")`, which resolves to the actual binary: `/snap/m0x41-podman/<revision>/usr/bin/podman`. This path is embedded as the `ExecStart` of the transient service unit.

The function propagates `PATH` via `--setenv=PATH=...` but does **not** propagate `LD_LIBRARY_PATH` or any `CONTAINERS_*` environment variables.

### Why the Shim Cannot Help

The snap's invocation chain is:

1. `/usr/local/bin/podman` (shim) sets `LD_LIBRARY_PATH`, then `exec`s the real binary
2. `exec()` replaces the process — `/proc/self/exe` now resolves to the real binary
3. _Podman_ reads `/proc/self/exe` and embeds that path in the transient unit
4. systemd fires the timer → bare binary → no `LD_LIBRARY_PATH` → library not found

The shim disappears after `exec()`. This is true regardless of whether the shim is a bash script or a compiled binary — `exec()` always replaces the process image and `/proc/self/exe` always resolves to the final binary.

### Why the Wrappers Cannot Help

The `conmon-wrapper` and `crun-wrapper` solve a different problem: _Podman_ invokes `conmon` and `crun` via paths in `containers.conf`, which we control. But _Podman_ does not look up its own path from config — it uses `/proc/self/exe`. There is no `engine.podman_binary` key, no `PODMAN_BINARY` environment variable, and no other override mechanism (confirmed against the v5.8.1 source).

## Impact

### Rootless

Healthcheck transient units created by `systemd-run --user` fail. The containers run but their healthchecks do not execute, so `podman healthcheck run` succeeds interactively but the automated timer-driven checks never pass.

### Rootful

Healthcheck transient units created by `systemd-run` (system scope) fail with the same error. The root shim at `/usr/local/bin/podman` has the same `exec()` limitation.

## Solutions Evaluated

### 1. Compiled Binary Wrapper — Does Not Work

A compiled C wrapper at `/usr/local/bin/podman` that sets `LD_LIBRARY_PATH` and `exec`s the real binary would have the same problem. After `exec()`, `/proc/self/exe` resolves to the real binary, not the wrapper. This approach was rejected.

### 2. System-Wide `ldconfig` — Rejected

Registering the snap's library directories in `/etc/ld.so.conf.d/` was the original approach. It caused `systemd-networkd` and `systemd-resolved` to load the snap's `libseccomp.so.2.5.3` instead of the system's `2.5.5`, resulting in SIGSEGV crashes on boot. This approach is permanently rejected.

### 3. User Environment Generator — Rootless Only

A script at `/usr/lib/systemd/user-environment-generators/60-m0x41-podman` that outputs `LD_LIBRARY_PATH=...` would inject the variable into the user systemd environment. All user units, including transient healthcheck units, would inherit it.

**Ordering mitigates risk.** By placing system library paths before snap paths:

```
LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/snap/m0x41-podman/current/usr/lib/x86_64-linux-gnu:/snap/m0x41-podman/current/lib/x86_64-linux-gnu:/snap/m0x41-podman/current/usr/lib
```

System libraries are found first. The snap paths only contribute libraries the system does not provide (e.g. `libyajl`). The RCCA #3 scenario — where the snap's `libseccomp` shadows the system's — cannot occur with this ordering.

**Scope concern.** The `LD_LIBRARY_PATH` applies to all user systemd units, not just _Podman_. On a general-purpose host, non-_Podman_ services running under `systemctl --user` would inherit it. With system paths first, the practical risk is negligible: the snap's unique libraries (`libyajl`, etc.) are not linked by non-_Podman_ software, so they would never be loaded by unrelated services. The only theoretical concern is that `LD_LIBRARY_PATH` is searched before a binary's `DT_RUNPATH` — but with system paths first, the binary receives the same system library it would have gotten from the `ldconfig` cache. A user who encounters edge-case interference can reorder the path.

**Limitation.** This approach solves rootless only. System-scope environment generators would affect all system services, recreating the RCCA #3 blast radius. Not viable for rootful healthchecks.

An equivalent alternative is creating `/etc/environment.d/60-m0x41-podman.conf`, which is read by the existing `30-systemd-environment-d-generator`. Same effect, standard mechanism.

### 4. Transient Unit Monitor Script — Fragile

A script or systemd path unit that watches `/run/systemd/transient/` for new healthcheck units and patches their `Environment=` directive is theoretically possible but has fundamental problems:

- **Race condition** — the timer can fire before the script detects and patches the unit
- **Transient units are systemd-managed** — modifying files under `/run/systemd/transient/` and reloading mid-execution is fragile and undocumented
- **Ongoing maintenance** — must handle unit naming conventions, scope (system vs user), and snap revision changes
- **Two-process coupling** — the monitor must understand _Podman_'s internal naming scheme for healthcheck units

This approach was rejected as too fragile for a general-purpose package.

### 5. Source Patch to `createTimer()` — Recommended

_Podman_ already propagates `PATH` via `--setenv=PATH=...` in `createTimer()`. The fix is to propagate `LD_LIBRARY_PATH` using the identical pattern. The patch to `libpod/healthcheck_linux.go` is three lines:

```go
ldLibPath := os.Getenv("LD_LIBRARY_PATH")
if ldLibPath != "" {
    cmd = append(cmd, "--setenv=LD_LIBRARY_PATH="+ldLibPath)
}
```

This is inserted immediately after the existing `PATH` propagation block.

**Properties:**
- Scoped to the transient unit only — no system-wide or user-wide environment changes
- Works for both rootless and rootful
- Follows the existing upstream convention
- Three lines of Go, one file, no architectural changes
- No fork required — applied via `sed` or `patch` in the snapcraft `override-build` step before `make podman`
- The Go `-overlay` build flag is an alternative if modifying the source tree is undesirable

**Build integration:** The patch file at `patches/healthcheck-ld-library-path.patch` is applied in the `podman` part's `override-build` step in `snapcraft.yaml`:

```yaml
override-build: |
  patch -p1 < $CRAFT_PROJECT_DIR/patches/healthcheck-ld-library-path.patch
  # ... existing build steps
```

## Testing

Section 5g of `scripts/05_run_tests.sh` validates the fix for both rootful and rootless:

| Test | What It Validates |
|------|-------------------|
| Container starts with healthcheck | Basic healthcheck container lifecycle |
| Transient timer exists | `systemd-run` created the timer unit |
| Transient service has `LD_LIBRARY_PATH` | The patch propagated the environment variable |
| Manual healthcheck run succeeds | The healthcheck binary can find its libraries |
| Status is healthy | End-to-end healthcheck is functional |

All five tests run for both rootful (system scope) and rootless (user scope), totalling 10 tests.

## Recommended Approach

Apply solution 5 (source patch) as the primary fix. It solves both rootless and rootful with zero side effects.

Solution 3 (user environment generator) may be added as a belt-and-braces measure for rootless, ensuring `LD_LIBRARY_PATH` is available to all user-scope _Podman_ operations, not just healthchecks. If adopted, the system-paths-first ordering described above must be used.

## Security Review

A comprehensive security analysis of this patch is in [PATCH_SECURITY_REVIEW.md](PATCH_SECURITY_REVIEW.md), covering the systemd security model, attack surface analysis, known `LD_LIBRARY_PATH` CVEs, and ecosystem precedent (Flatpak, NixOS).

## Upstream Contribution

The patch is a candidate for upstream submission to `containers/podman`. The rationale — that `LD_LIBRARY_PATH` should be propagated alongside `PATH` in transient healthcheck units — applies to any packaging system where _Podman_'s libraries are not in the default linker path (snaps, AppImage, custom prefix installs). The change follows the existing code pattern and has no effect when `LD_LIBRARY_PATH` is unset.
