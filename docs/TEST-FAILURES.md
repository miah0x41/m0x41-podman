# Test Failures by Tier and Environment

This document records every known test failure in the `m0x41-podman` snap test suite, grouped by tier. Each failure indicates whether it occurs in LXC containers, LXD VMs, or both, along with the root cause classification.

Last re-validated 2026-08-15 against _Podman_ v5.8.6 (`v5.8.6+snap1`) on Ubuntu 24.04 (LXD VM). Tiers 1–6 were run in both an LXD container and an LXD VM; Tier 7 (full BATS) was run in the VM in both root and rootless modes. The LXC-vs-VM recovery analysis in the Tier 7 section is carried from the original 2026-04-06 baseline, since Tier 7 was not re-run under LXC for this bump; the VM figures below reflect the v5.8.6 run.

Figures postdate the `pipefail`/`grep -q` harness fix in [investigations/RCCA-PIPEFAIL-GREPQ.md](investigations/RCCA-PIPEFAIL-GREPQ.md). Before that fix, assertions piping a slow producer into `grep -q` could report a successful match as a failure, so a handful of failures in earlier baselines were spurious.

## Summary

| Tier | LXC Failures | VM Failures | Notes |
|------|-------------|-------------|-------|
| 1 | 0 | 0 | |
| 2 | 0 | 0 | |
| 3 | 0 | 0 | |
| 4 | 3 | 3 | Same 3 snap config failures in both |
| 5a-d | 0 | 0 | |
| 5e | 3 | 2 | VM recovers 1 (`userns`, needs full kernel) |
| 5g | — | 0 | VM only; no LXC data |
| 6 | — | 0 | VM only |
| 7 (root) | — | 21 of 607 applicable | 179 skipped (pasta, SELinux, etc.); adapted shim recovers to 639/786 combined |
| 7 (rootless) | — | 23 of 610 applicable | 87 skipped + 89 `pasta` not applicable; adapted shim recovers to 711/786 combined |

---

## Tier 1: Snap Command Validation

**LXC:** 7/7 pass | **VM:** 7/7 pass

No failures.

---

## Tier 2: Rootless Functional

**LXC:** 8/8 pass | **VM:** 8/8 pass

No failures.

---

## Tier 3: Rootful Functional

**LXC:** 6/6 pass | **VM:** 6/6 pass

No failures.

---

## Tier 4: BATS Parity (Smoke Tests)

**LXC:** 28/31 | **VM:** 28/31

Three failures in both environments. All are snap-specific config conflicts — the snap sets `CONTAINERS_CONF` and `CONTAINERS_STORAGE_CONF` environment variables that override the BATS test harness's temporary config.

| Test | File | Environment | Root Cause |
|------|------|-------------|------------|
| `podman info - json` | `005-info.bats` | Both | Snap's `CONTAINERS_CONF` overrides test config; teardown cleans up state that was never created |
| `CONTAINERS_CONF_OVERRIDE` | `005-info.bats` | Both | Test sets `CONTAINERS_CONF` — snap env var takes precedence |
| `empty string defaults` | `005-info.bats` | Both | Test expects a warning when no storage driver is configured; snap always provides `CONTAINERS_STORAGE_CONF` |

All three pass in the native build. These are a fundamental trade-off of snap packaging — the snap must control its config paths to function.

---

## Tier 5: Quadlet / Install Hook

### 5a-d: Install Hook and Quadlet Validation

**LXC:** 20/20 pass | **VM:** 20/20 pass

No failures.

### 5e: Upstream BATS Quadlet and System-Service Tests

**LXC:** 70/73 | **VM:** 71/73

| Test | File | Environment | Root Cause |
|------|------|-------------|------------|
| `quadlet - basic` | `252-quadlet.bats` | Both | Quadlet-generated unit times out waiting for container output (`STARTED CONTAINER` never seen) |
| `quadlet - envvar` | `252-quadlet.bats` | Both | Environment variable passthrough differs under snap shim |
| `quadlet - userns` | `252-quadlet.bats` | LXC only | LXD container lacks full user namespace support for this test |

Tests `253-podman-quadlet.bats` (9/9), `254-podman-quadlet-multi.bats` (5/5), `251-system-service.bats` (19/19), and `270-socket-activation.bats` (3/3) pass in both environments.

### 5g: Healthcheck Transient Unit Validation

**VM:** 16/16 pass | **LXC:** 16/16 pass

No failures. For both rootful and rootless: transient timers are created, `ExecStart` references the shim (not the raw snap binary), `LD_LIBRARY_PATH` and all `CONTAINERS_*` config env vars are propagated, and the timer-triggered healthcheck reports healthy status. Tests use a 5-second health interval and wait for the timer to fire — they do not use manual `podman healthcheck run` (which would go through the shim and mask transient unit configuration issues).

---

## Tier 6: Host-Side Impact (VM Only)

**VM:** 31/31 pass

No failures across network integrity (5), library path integrity (3), systemd health (3), reboot survival (9), and snap removal cleanup (11).

Tier 6 requires a VM that has not run the Tier 7 BATS suite: the upstream suite leaves failed transient units behind (`container-c_image_*`, `podman-kube@-tmp-podman_bats.*`) which the 6c assertion then attributes to the snap.

---

## Tier 7: Full Upstream BATS Suite

### Root Mode (VM)

Of the 786 upstream tests, 179 are skipped by the test harness — tests for `pasta` networking, SELinux, checkpoint/restore, and SSH/remote, none of which the snap ships. Of the **607 applicable tests**:

**Pass 1 (upstream shim):** 585 pass (96.4%), 22 failures. **Pass 2 (adapted shim):** recovers config-sensitive files to **638/786 combined**.

The 22 residual Pass 1 failures are classified below.

#### Root Failures by File (22, VM)

| File | Fail | Classification | Root Cause |
|------|------|----------------|------------|
| `331-system-check.bats` | 11 | Infra | `podman-testing` helper runs outside the snap and cannot find the bundled `conmon` |
| `005-info.bats` | 2 | Snap config | `CONTAINERS_CONF` / `CONTAINERS_STORAGE_CONF` precedence (recovered by adapted shim) |
| `252-quadlet.bats` | 2 | Snap | `basic` (container-output timeout) and `envvar` (env passthrough under shim) |
| `220-healthcheck.bats` | 2 | Environment | journal/events log query + PATH-manipulation test artifact |
| `030-run.bats` | 2 | Environment | `check workdir` and `oom-score-adj` assertions under snap env |
| `060-mount.bats` | 1 | Environment | mount assertion under VM |
| `200-pod.bats` | 1 | Environment | pod timing |
| `500-networking.bats` | 1 | Snap | `slirp4netns` restart latency vs `pasta` |

#### Adapted Shim Recoveries (5 tests)

These tests pass when the shim respects pre-existing config environment variables:

| Test | File |
|------|------|
| `podman info - json` | `005-info.bats` |
| `podman run --init` | `030-run.bats` |
| `podman build no --dns with --network` | `070-build.bats` |
| `containers.conf read-only` | `800-config.bats` |
| `containers.conf tmpdir` | `800-config.bats` |

The `generate systemd` / `runlabel` binary-path failures noted in earlier baselines no longer occur: `250-systemd.bats`, `255-auto-update.bats`, and `037-runlabel.bats` pass in root mode on v5.8.6. The `generate-systemd-binary-path.patch` (`PODMAN_BINARY` override) makes generated units reference the shim at `/usr/local/bin/podman` rather than the snap-internal path — confirmed in the Tier 5 dry-run assertions and directly in the `250-systemd` output. See [investigations/RCCA-ADAPTED-FAILURES.md](investigations/RCCA-ADAPTED-FAILURES.md) for the original analysis.

### Rootless Mode (VM)

**VM:** 786 tests — 587 pass, 87 skipped, 112 raw failures. **Pass 2 (adapted shim):** recovers to **711/786 combined**.

The snap bundles `slirp4netns` instead of `pasta` for rootless networking. In root mode, the test harness detects `pasta` as absent and skips these tests; in rootless mode, the same tests attempt to run and fail. The 89 `pasta` failures are not applicable to the snap and should be excluded from the pass rate.

**Excluding `pasta`: 587/610 applicable tests (96.2%)**, 23 real failures.

| File | Fail | Classification | Root Cause |
|------|------|----------------|------------|
| `505-networking-pasta.bats` | 84 | Not applicable | `pasta` networking — snap ships `slirp4netns` |
| `331-system-check.bats` | 11 | Infra | `podman-testing` cannot find snap's `conmon` (same as root) |
| `500-networking.bats` | 5 | Not applicable | `pasta`-dependent networking under rootless |
| `005-info.bats` | 2 | Snap config | `CONTAINERS_CONF` precedence (recovered by adapted shim) |
| `220-healthcheck.bats` | 2 | Environment | journal/events log query + PATH-manipulation artifact |
| `250-systemd.bats` | 2 | Environment | `service_cleanup` timing + rootless-netns cgroup assertion |
| `252-quadlet.bats` | 2 | Snap | `basic` + `envvar` (same as root) |
| `800-config.bats` | 2 | Snap config | config precedence (recovered by adapted shim) |
| `030-run.bats` | 1 | Environment | run assertion under snap env |
| `200-pod.bats` | 1 | Environment | pod timing |

---

## Root Cause Classification

All failures across tiers 1-7 fall into five categories:

| Classification | Description | Tiers Affected | Fixable? |
|---------------|-------------|----------------|----------|
| **Snap config override** | Shim force-sets config env vars, overriding test harness | 4, 5e, 7 | Partially — 5 recoverable via adapted shim; rest structural |
| **Snap binary path** | _Podman_ resolves `/proc/self/exe` to snap internal path | 7 | No — `podman generate systemd` is deprecated; use Quadlet |
| **Missing `pasta`** | `core22` base lacks `pasta`/`passt` | 7 (rootless) | Future — migrate to `core24` base |
| **LXD limitations** | Container kernel restrictions vs full VM | 5e, 7 | Yes — use VM for authoritative results |
| **Test infrastructure** | Missing tools, registry state, timing races | 5e, 7 | Partially — `buildah` and `htpasswd` added; `podman-testing` infra-limited |

---

## References

- [TESTING.md](TESTING.md) — test methodology and how to run tests
- [TESTING-RESULTS.md](TESTING-RESULTS.md) — recorded pass/fail counts and tables
- [investigations/RCCA-BATS-FAILURES.md](investigations/RCCA-BATS-FAILURES.md) — tier 7 root cause analysis
- [investigations/RCCA-ADAPTED-FAILURES.md](investigations/RCCA-ADAPTED-FAILURES.md) — adapted pass residual failures
- [investigations/RCCA-LIBRARY-POISONING.md](investigations/RCCA-LIBRARY-POISONING.md) — host library path poisoning (tier 6 motivation)
