# Patch Security Review: Healthcheck `LD_LIBRARY_PATH` Propagation

The snap applies one upstream source modification: a 3-line patch to `libpod/healthcheck_linux.go` that propagates `LD_LIBRARY_PATH` into healthcheck transient systemd units via `--setenv`. This document analyses the security implications of that patch.

For the functional root cause analysis, see [HEALTHCHECK_ISSUES.md](HEALTHCHECK_ISSUES.md).

## The Patch

```go
ldLibPath := os.Getenv("LD_LIBRARY_PATH")
if ldLibPath != "" {
    cmd = append(cmd, "--setenv=LD_LIBRARY_PATH="+ldLibPath)
}
```

Inserted immediately after the existing `PATH` propagation in `createTimer()`. Applied at build time via `patches/healthcheck-ld-library-path.patch`.

## Why Upstream Omits `LD_LIBRARY_PATH`

The `PATH` propagation was added in [containers/podman#8438](https://github.com/containers/podman/pull/8438) (November 2020) as a point fix for NixOS, where binaries live in non-standard paths. The reviewer approved with "LGTM" — no security analysis, no discussion of which other variables should or should not be propagated. `LD_LIBRARY_PATH` was omitted because standard packaging (RPM, deb) never sets it, so there was nothing to propagate.

No upstream issue, PR, or discussion has ever addressed this gap. The omission was not a deliberate security decision — it was simply never needed by anyone who filed an issue. The snap packaging model (bundling all dependencies in a non-standard path that requires `LD_LIBRARY_PATH`) is the first context where this becomes necessary.

## systemd Principles

systemd's transient service units (created by `systemd-run` without `--scope`) start with a clean environment — they do not inherit the caller's variables. This is a deliberate design: Lennart Poettering has stated that services invoked by systemd start with a clean environment, a significant departure from SysV init where daemon environments were inherited from the user session.

The `--setenv` flag is the **sanctioned mechanism** for providing environment variables to transient services. It is functionally identical to `Environment=` in a `.service` file. systemd does not actively filter or block `LD_LIBRARY_PATH`; the protection is through absence (clean environment), not prohibition. Using `--setenv` respects the security model rather than circumventing it.

This is distinct from `systemd-run --scope`, which inherits the full caller environment. _Podman_'s healthcheck uses transient **service** units (the more secure model), so only explicitly declared variables are present.

## Attack Surface Analysis

### Can a Container Influence the Propagated Value?

No. The `LD_LIBRARY_PATH` originates from `podman-wrapper`, which hardcodes the snap paths:

```bash
export LD_LIBRARY_PATH="$SNAP/usr/lib/x86_64-linux-gnu:$SNAP/lib/x86_64-linux-gnu:$SNAP/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

The container's environment is isolated by Linux namespaces (mount, PID, network, user). It cannot modify the host _Podman_ process's environment variables. The value is determined before any container is created.

### Can an Attacker Place Malicious Libraries in the Snap Paths?

No. `/snap/m0x41-podman/<revision>/` is a read-only squashfs mount. Modifying it requires root access to the host, at which point `LD_LIBRARY_PATH` injection is irrelevant — the attacker already has full control.

### Rootful Privilege Escalation

No UID/GID transition occurs — the transient unit runs at the same privilege level as the caller. `glibc`'s `AT_SECURE` / secure-execution mode is not triggered. However, this is irrelevant because the library paths are read-only and attacker-inaccessible. The security properties are identical to any root-owned systemd service with `Environment=LD_LIBRARY_PATH=...` in its unit file.

### Argument Injection via Malformed Value

The value is appended to the `systemd-run` command via Go's `exec.Command`, which passes arguments as a string array — not through a shell. A value containing spaces or shell metacharacters is passed correctly as a single argument. This is the same pattern used for `PATH` and is safe against injection.

### Pre-Existing `LD_LIBRARY_PATH` From Caller

The wrapper appends `${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}`, so if the user had `LD_LIBRARY_PATH` set before invoking the snap, those paths are included. A user who can set `LD_LIBRARY_PATH` before running `podman` already controls the _Podman_ process itself — no privilege boundary is crossed.

## Comparison to Existing `PATH` Propagation

| Property | `PATH` (upstream) | `LD_LIBRARY_PATH` (this patch) |
|---|---|---|
| Can cause arbitrary code execution | Yes (trojan binary) | Yes (trojan library) |
| Stripped by `glibc` secure-execution mode | No | Yes |
| Already propagated upstream | Yes | No |
| Defence-in-depth protection from `glibc` | None | `AT_SECURE` strips it for setuid/setgid |

`PATH` is strictly more dangerous than `LD_LIBRARY_PATH` — `glibc` provides no automatic protection against `PATH` manipulation. The upstream decision to propagate `PATH` but not `LD_LIBRARY_PATH` was an oversight driven by the fact that standard packaging never sets `LD_LIBRARY_PATH`, not a deliberate security boundary.

## Blast Radius

The `LD_LIBRARY_PATH` is scoped to the individual transient service unit. It does not affect:

- Other systemd services (system or user scope)
- The user's login environment
- The system-wide linker cache (`ldconfig`)
- Other transient units
- Unrelated processes

This is a critical improvement over the previous approach (system-wide `ldconfig` poisoning, see [RCCA #3](../RCCA-3-podman-snap-library-poisoning.md)), which affected every process on the host and caused `systemd-networkd` and `systemd-resolved` to crash with SIGSEGV.

## Known `LD_LIBRARY_PATH` Vulnerability Classes

| CVE | Description | Relevance |
|-----|-------------|-----------|
| CVE-2023-4911 (Looney Tunables) | Buffer overflow in `glibc`'s `ld.so` triggered by crafted `GLIBC_TUNABLES` | Not triggered by `LD_LIBRARY_PATH`. Not relevant |
| CVE-2025-4802 | `glibc` 2.27–2.38 honoured `LD_LIBRARY_PATH` via `dlopen` in statically compiled setuid binaries | _Podman_'s healthcheck binary is dynamically linked and not setuid. Not relevant |
| CVE-2017-1000366 | `glibc` vulnerability allowing `LD_LIBRARY_PATH` to manipulate heap/stack | Fixed in `glibc` 2.26. The snap's `glibc` floor is 2.34. Not relevant |
| CVE-2023-31210 | User-controlled `LD_LIBRARY_PATH` in an agent leading to code execution | The value here is controlled by the snap wrapper, not user input. Not relevant |
| MITRE ATT&CK T1574.006 | Dynamic Linker Hijacking via `LD_LIBRARY_PATH` | Requires attacker to control the value or write to referenced directories. Neither is achievable here — the value is hardcoded and the directories are read-only squashfs |

## Ecosystem Precedent

### Flatpak

Flatpak encountered the identical problem: when `bwrap` (bubblewrap) runs as setuid-root, the kernel strips `LD_LIBRARY_PATH` from the inherited environment. The fix ([flatpak/flatpak#4081](https://github.com/flatpak/flatpak/pull/4081)) was to explicitly convert environment variables into `--setenv` arguments for `bwrap` — the exact same pattern as this patch.

### NixOS

NixOS wraps systemd services that need custom library paths in shell scripts — the same approach as the `conmon-wrapper` and `crun-wrapper` in this snap. NixOS also had to add `systemd` to `extraPackages` ([NixOS/nixpkgs#362372](https://github.com/NixOS/nixpkgs/pull/362372)) to make `systemd-run` available for _Podman_ healthchecks.

### Snap Classic Linter

Canonical's snapcraft classic linter recommends RPATH with `$ORIGIN` for library resolution, enforced via ELF patching. RPATH would be the ideal long-term solution, but faces practical limitations: _Podman_ is a Go/CGO binary, and the `go build` toolchain does not straightforwardly support RPATH for all linked C libraries.

## Long-Term Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| RPATH / RUNPATH (link-time) | No environment variable needed; recommended by Snap, NixOS, AppImage communities | Go/CGO does not straightforwardly support RPATH for all linked C libraries |
| `patchelf --set-rpath` (post-build) | Can be applied to pre-built binaries | Must be re-applied after every _Podman_ version update; fragile with CGO |
| `--setenv` propagation (this patch) | Minimal change, follows existing upstream pattern, matches Flatpak precedent | Modifies upstream source; must be carried as a patch |
| User environment generator | Standard systemd mechanism for rootless | Rootless only; affects all user units, not just _Podman_ |
| System-wide `ldconfig` | No source modification needed | **Permanently rejected** — caused RCCA #3 incident |

The `--setenv` approach is the best available option given the constraints. RPATH should be revisited if Go's CGO toolchain improves or if the snap moves to statically linked builds.

## Verdict

The patch is sound. It:

- Follows the existing upstream pattern (`PATH` propagation)
- Uses systemd's sanctioned mechanism (`--setenv`)
- Has the narrowest possible scope (individual transient unit)
- Cannot be influenced by container workloads
- Targets read-only library paths
- Introduces no new privilege escalation path
- Is consistent with Flatpak's solution to the same class of problem
- Does not trigger any known CVE or vulnerability class

No security vulnerabilities were identified.
