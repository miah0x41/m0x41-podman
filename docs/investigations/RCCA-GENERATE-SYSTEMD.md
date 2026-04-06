# RCCA #4: `podman generate systemd` Embeds Snap Internal Binary Path

**Date of Investigation:** 2026-04-06
**Environment:** LXD VM (Ubuntu 24.04), bare-metal KVM
**Related:** [RCCA-ADAPTED-FAILURES.md](RCCA-ADAPTED-FAILURES.md) (Category 1: 15 failures), [RCCA-BATS-FAILURES.md](RCCA-BATS-FAILURES.md) (Category 2)

---

## 1. Symptom

`podman generate systemd` produces unit files with `ExecStart=` lines that reference the snap's internal binary path:

```
ExecStart=/snap/m0x41-podman/x1/usr/bin/podman start <container-id>
```

When systemd invokes this path directly, the binary runs outside the snap's wrapper environment — without `LD_LIBRARY_PATH`, `PATH`, or config env vars. The unit fails immediately:

```
Error: could not find a working conmon binary (configured options:
[/usr/libexec/podman/conmon /usr/local/libexec/podman/conmon ...]: invalid argument)
```

This causes 18 of 22 residual adapted-pass failures in the tier 7 full BATS suite:
- `250-systemd.bats` — 5 failures
- `255-auto-update.bats` — 10 failures
- `037-runlabel.bats` — 1 failure
- `252-quadlet.bats` — 2 failures (adapted shim artefact)

---

## 2. Root Cause

_Podman_ resolves its own binary path using `os.Executable()`, which reads `/proc/self/exe`. In a snap, the wrapper at `/usr/local/bin/podman` is a shell shim that sets up the environment and then `exec`s the real binary. After `exec()`, `/proc/self/exe` resolves to the real binary inside the snap (`/snap/m0x41-podman/x1/usr/bin/podman`), not the shim.

The resolution chain:

1. User invokes `/usr/local/bin/podman generate systemd ...` (the shim)
2. Shim sets `LD_LIBRARY_PATH`, `PATH`, config env vars
3. Shim runs `exec "$SNAP/usr/bin/podman" "$@"`
4. `exec()` replaces the process — `/proc/self/exe` now points to the snap binary
5. `os.Executable()` → `/snap/m0x41-podman/x1/usr/bin/podman`
6. This path is embedded in the generated unit's `ExecStart=`
7. systemd runs the bare snap binary → no wrapper environment → failure

A related but distinct mechanism affects `podman container runlabel --display`. The `--display` code path (line 73 of `containers_runlabel.go`) bypasses the `substituteCommand()` function entirely and uses `os.Args[0]` directly to print the command. After `exec()`, `os.Args[0]` resolves to the snap internal binary — the same leak, but via a different Go API.

**Source locations** (Podman v5.8.1):
- `pkg/systemd/generate/containers.go` line 301: `executable, err := os.Executable()`
- `pkg/systemd/generate/pods.go` line 286: `executable, err := os.Executable()`
- `pkg/domain/infra/abi/containers_runlabel.go` line 73: `os.Args[0]` (in `--display` branch)

---

## 3. Comparison with Healthcheck Issue

The [healthcheck transient unit issue](HEALTHCHECK_ISSUES.md) has a similar root cause — _Podman_ creates systemd units that invoke the bare binary. The healthcheck fix propagates `LD_LIBRARY_PATH` via `--setenv` in `systemd-run` calls.

That approach does not work here because:
- Healthchecks: _Podman_ creates transient units at runtime via `systemd-run` and controls `--setenv` flags
- `generate systemd`: _Podman_ outputs static unit file text — it cannot inject environment variables into future systemd invocations

The correct fix is to override the binary path itself so the generated unit references the shim (`/usr/local/bin/podman`) rather than the snap internal binary.

---

## 4. Fix

### Patch: `PODMAN_BINARY` Environment Variable Override

A patch to three files checks for a `PODMAN_BINARY` environment variable and overrides the resolved binary path if set. Two distinct patterns are used.

**Pattern 1 — `os.Executable()` override** (`pkg/systemd/generate/containers.go` and `pods.go`):

```go
executable, err := os.Executable()
if err != nil {
    executable = "/usr/bin/podman"
    logrus.Warnf("Could not obtain podman executable location, using default %s", executable)
}
// Allow snap/wrapper environments to override the resolved binary path.
if override := os.Getenv("PODMAN_BINARY"); override != "" {
    executable = override
}
info.Executable = executable
```

**Pattern 2 — `os.Args[0]` override** (`pkg/domain/infra/abi/containers_runlabel.go`):

```go
displayBin := os.Args[0]
// Allow snap/wrapper environments to override the resolved binary path.
if override := os.Getenv("PODMAN_BINARY"); override != "" {
    displayBin = override
}
fmt.Printf("command: %s\n", strings.Join(append([]string{displayBin}, cmd[1:]...), " "))
```

The `runlabel --display` code path requires a different pattern because it uses `os.Args[0]` directly rather than `os.Executable()`, and the display branch bypasses the `substituteCommand()` function entirely.

The patch file is at `patches/generate-systemd-binary-path.patch`.

### Wrapper and Shim Changes

Both entry points to the snap's _Podman_ binary export the override before exec'ing:

The wrapper (`scripts/podman-wrapper`) and the install hook shim (`snap/hooks/install`, which writes `/usr/local/bin/podman`) both set:

```bash
export PODMAN_BINARY="/usr/local/bin/podman"
```

Both entry points need the variable because `podman` can be invoked through either the wrapper (`snap run m0x41-podman` or snap alias) or the shim (`/usr/local/bin/podman`, used by systemd units, Quadlet services, and direct invocation).

### Properties

- **Non-breaking**: Falls back to `os.Executable()` / `os.Args[0]` when `PODMAN_BINARY` is not set
- **Minimal**: 3-4 lines per source file, 1 line each in wrapper and shim
- **Scoped**: Only affects code paths that embed the binary path in text outputs
- **Consistent**: Follows the same env var override pattern as `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`

---

## 5. Verified Impact

### Tests Recovered

Verified 2026-04-06 on LXD VM (Ubuntu 24.04), root mode.

Of the 22 adapted-pass residual failures, 16 are directly recovered by the `PODMAN_BINARY` patch:

| File | Before | After | Mechanism |
|------|--------|-------|-----------|
| `250-systemd.bats` | 11/16 | 16/16 | `podman generate systemd` units now reference shim |
| `255-auto-update.bats` | 2/12 | 12/12 | Auto-update units created via `generate systemd` |
| `037-runlabel.bats` | 0/1 | 1/1 | `podman container runlabel --display` now shows shim path |

The 2 `252-quadlet.bats` failures are adapted shim test artefacts (production shim already passes). The remaining 4 failures have other root causes (infra, registry, timing) — see [RCCA-ADAPTED-FAILURES.md](RCCA-ADAPTED-FAILURES.md).

---

## 6. Limitations

**`podman generate systemd` is deprecated.** Upstream _Podman_ has deprecated this command in favour of Quadlet. The snap's Quadlet integration works correctly — the install hook's systemd generators reference `/usr/local/bin/podman` (the shim), not the snap internal path.

This patch improves compatibility with the deprecated path but is not required for production use. Users should prefer Quadlet `.container` files for systemd integration.

**`PODMAN_BINARY` is snap-specific.** This env var is not part of upstream _Podman_. If the env var is accidentally set to a non-existent path, generated units will reference that path. The risk is minimal — it is only set by the wrapper, which always sets it to the shim.

---

## 7. Security Considerations

The patch does not introduce security concerns:

- `PODMAN_BINARY` only affects the text output of `podman generate systemd` and related commands
- It does not change which binary is actually executed
- The env var is set by the wrapper and shim (controlled by the snap package), not by user input
- An attacker who can set environment variables can already control `PATH`, `CONTAINERS_CONF`, etc.

For the full security review, see [PATCH_SECURITY_REVIEW_BINARY_PATH.md](PATCH_SECURITY_REVIEW_BINARY_PATH.md).

---

## 8. References

- [RCCA-ADAPTED-FAILURES.md](RCCA-ADAPTED-FAILURES.md) — full analysis of the 22 adapted-pass residual failures
- [RCCA-BATS-FAILURES.md](RCCA-BATS-FAILURES.md) — initial tier 7 failure classification
- [HEALTHCHECK_ISSUES.md](HEALTHCHECK_ISSUES.md) — related issue with healthcheck transient units
- [PATCH_SECURITY_REVIEW.md](PATCH_SECURITY_REVIEW.md) — security review of the healthcheck patch
- [PATCH_SECURITY_REVIEW_BINARY_PATH.md](PATCH_SECURITY_REVIEW_BINARY_PATH.md) — security review of this patch
- `patches/generate-systemd-binary-path.patch` — the patch file
- `patches/healthcheck-ld-library-path.patch` — the analogous healthcheck patch
