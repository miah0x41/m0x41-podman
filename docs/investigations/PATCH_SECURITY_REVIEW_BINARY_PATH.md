# Patch Security Review: Binary Path Override via `PODMAN_BINARY`

The snap applies two upstream source modifications to _Podman_. This document analyses the security implications of the second patch: a `PODMAN_BINARY` environment variable override that controls which binary path appears in generated text output. The first patch (healthcheck transient unit environment propagation, including `PODMAN_BINARY`, `LD_LIBRARY_PATH`, and `CONTAINERS_*` config vars) is reviewed separately in [PATCH_SECURITY_REVIEW.md](PATCH_SECURITY_REVIEW.md).

For the functional root cause analysis, see [RCCA-GENERATE-SYSTEMD.md](RCCA-GENERATE-SYSTEMD.md).

## The Patch

The patch modifies three files with two distinct patterns. Applied at build time via `patches/generate-systemd-binary-path.patch`.

**Pattern 1 — `os.Executable()` override** (`pkg/systemd/generate/containers.go` and `pods.go`):

```go
// Allow snap/wrapper environments to override the resolved binary path.
if override := os.Getenv("PODMAN_BINARY"); override != "" {
    executable = override
}
```

Inserted after `os.Executable()` resolves the binary path. If `PODMAN_BINARY` is set, the value replaces the resolved path in the generated systemd unit text.

**Pattern 2 — `os.Args[0]` override** (`pkg/domain/infra/abi/containers_runlabel.go`):

```go
displayBin := os.Args[0]
// Allow snap/wrapper environments to override the resolved binary path.
if override := os.Getenv("PODMAN_BINARY"); override != "" {
    displayBin = override
}
fmt.Printf("command: %s\n", strings.Join(append([]string{displayBin}, cmd[1:]...), " "))
```

Replaces the direct use of `os.Args[0]` in the `--display` branch. The original code bypassed `substituteCommand()` entirely and printed the kernel-resolved binary path.

## What the Patch Does and Does Not Do

**Does:** Controls what path text appears in:
- `podman generate systemd` output (`ExecStart=`, `ExecStop=`, `ExecStopPost=` lines)
- `podman container runlabel --display` output

**Does not:**
- Change which binary is actually executed by _Podman_
- Affect `os.Executable()`, `/proc/self/exe`, or actual process execution
- Inject environment variables into running processes (contrast with the healthcheck patch, which uses `systemd-run --setenv` to affect a real process's environment)
- Affect Quadlet-generated units (those already reference the shim via the install hook's systemd generators)

The critical distinction from the healthcheck patch: the healthcheck patch affects **runtime behaviour** (a real process inherits `LD_LIBRARY_PATH` via `--setenv`). This patch affects **text output only** (a string is written to stdout or a file).

## Attack Surface Analysis

### Can a Container Influence `PODMAN_BINARY`?

No. The environment variable originates from the wrapper (`scripts/podman-wrapper`) or shim (`snap/hooks/install`), both of which set it before any container operations begin. Container environments are isolated by Linux namespaces (mount, PID, network, user). A container process cannot modify the host _Podman_ process's environment variables.

### Can `PODMAN_BINARY` Cause Code Execution?

No. The value is written into the text of `ExecStart=` lines in unit files or printed to stdout. _Podman_ does not execute the value — it only embeds it as a string. A malicious value would produce a unit file whose `ExecStart=` references an attacker-controlled path, but:

1. The unit file must still be explicitly installed and started by a user or administrator
2. The unit file is not automatically loaded by systemd — `podman generate systemd` outputs text to stdout
3. An attacker who can set `PODMAN_BINARY` before _Podman_ runs already controls the entire _Podman_ process environment

### Argument Injection via Malformed Value

Not applicable. The value replaces a path string via Go string concatenation (`fmt.Sprintf` / `strings.Join`). It is not passed to a shell or `exec` call within _Podman_. Even if the value contained spaces, newlines, or shell metacharacters, the resulting unit file would have a malformed `ExecStart=` line that systemd would reject at load time — not execute.

### Who Controls the Value?

Only two code paths set `PODMAN_BINARY`:

1. `scripts/podman-wrapper` (line 4): `export PODMAN_BINARY="/usr/local/bin/podman"`
2. `snap/hooks/install` (the shim written to `/usr/local/bin/podman`): `export PODMAN_BINARY="/usr/local/bin/podman"`

Both are controlled by the snap package. Users cannot set `PODMAN_BINARY` through any _Podman_ CLI flag, configuration file, or container spec. It can only be set in the process environment before invoking `podman`.

### What if an Attacker Sets `PODMAN_BINARY` to a Malicious Path?

The generated unit file would reference that path in its `ExecStart=` line. If a user then installs and starts that unit, systemd would execute whatever binary is at the attacker's path.

However, an attacker who can set environment variables for the _Podman_ process already controls:
- `PATH` — can redirect any binary lookup
- `CONTAINERS_CONF` — can override the OCI runtime, storage driver, and all engine settings
- `LD_PRELOAD` — can inject arbitrary code into the _Podman_ process itself
- `LD_LIBRARY_PATH` — can redirect shared library resolution

No privilege boundary is crossed. The attacker already has a strictly more powerful capability set than `PODMAN_BINARY` provides.

## Comparison to Existing Overrides

| Variable | What It Controls | Security Impact |
|----------|-----------------|-----------------|
| `CONTAINERS_CONF` | OCI runtime, storage driver, engine config | Can change which runtime executes containers |
| `CONTAINERS_STORAGE_CONF` | Storage driver, graph root | Can redirect container storage to attacker-controlled paths |
| `LD_PRELOAD` | Shared libraries loaded into process | Arbitrary code execution within _Podman_ |
| `PATH` | Binary lookup for child processes | Can redirect `conmon`, `crun`, `netavark` to trojans |
| **`PODMAN_BINARY`** | **Text in generated unit files** | **Affects output text only; no runtime execution** |

`PODMAN_BINARY` has the narrowest security surface of any environment variable that _Podman_ or its runtime respects. It cannot cause code execution within the _Podman_ process and requires an additional user action (installing and starting a generated unit) before the value reaches systemd.

## Blast Radius

The `PODMAN_BINARY` value affects only:

- `podman generate systemd` — text output (`ExecStart=`, `ExecStop=`, `ExecStopPost=` lines)
- `podman generate systemd --new` — text output (same lines)
- `podman container runlabel --display` — text output (`command:` line)

It does **not** affect:

- Actual binary execution within _Podman_
- Quadlet-generated units (those reference the shim via systemd generators)
- Container runtime, networking, or storage
- Any other _Podman_ subcommand
- The host system environment

**Note:** The healthcheck patch (`healthcheck-ld-library-path.patch`) also uses `PODMAN_BINARY` to override the binary path in transient healthcheck units. Unlike this patch (which affects text output only), the healthcheck override affects a real `ExecStart` path that systemd executes. The security properties are equivalent — see [PATCH_SECURITY_REVIEW.md](PATCH_SECURITY_REVIEW.md).

## Verdict

The patch is sound. It:

- Affects text output only — not runtime execution
- Is strictly less security-sensitive than the healthcheck patch (which injects env vars into real processes via `--setenv`)
- Is strictly less security-sensitive than existing `CONTAINERS_CONF`, `PATH`, and `LD_PRELOAD` overrides
- Cannot be influenced by container workloads
- Requires additional user action (installing a generated unit) before the value reaches systemd
- Follows the same env var override pattern as `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`, and `CONTAINERS_REGISTRIES_CONF`
- Cannot cause argument injection (Go string concatenation, not shell evaluation)
- Introduces no new privilege escalation path

No security vulnerabilities were identified.
