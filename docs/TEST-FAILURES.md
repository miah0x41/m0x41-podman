# Test Failures by Tier and Environment

This document records every known test failure in the `m0x41-podman` snap test suite, grouped by tier. Each failure indicates whether it occurs in LXC containers, LXD VMs, or both, along with the root cause classification.

Tested 2026-04-06 on bare-metal KVM (VM). Ubuntu 24.04.

## Summary

| Tier | LXC Failures | VM Failures | Notes |
|------|-------------|-------------|-------|
| 1 | 0 | 0 | |
| 2 | 0 | 0 | |
| 3 | 0 | 0 | |
| 4 | 3 | 3 | Same 3 snap config failures in both |
| 5a-d | 0 | 0 | |
| 5e | 5 | 2 | VM recovers 3 (environment + `htpasswd`) |
| 5g | — | 0 | VM only; no LXC data |
| 6 | — | 0 | VM only |
| 7 (root) | 126 | 46 of 605 applicable | 180 skipped (pasta, SELinux, etc.); VM recovers 80; 5 more via adapted shim |
| 7 (rootless) | — | 100 of 611 applicable | 83 skipped + 91 `pasta` not applicable |

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

**LXC:** 68/73 | **VM:** 71/73

| Test | File | Environment | Root Cause |
|------|------|-------------|------------|
| `quadlet - basic` | `252-quadlet.bats` | Both | Quadlet-generated unit times out waiting for container output (`STARTED CONTAINER` never seen) |
| `quadlet - envvar` | `252-quadlet.bats` | Both | Environment variable passthrough differs under snap shim |
| `quadlet - userns` | `252-quadlet.bats` | LXC only | LXD container lacks full user namespace support for this test |
| `quadlet - image files` | `252-quadlet.bats` | LXC only | Passes in VM with full kernel isolation |
| `quadlet - artifact` | `252-quadlet.bats` | LXC only | Passes in VM with `apache2-utils` (`htpasswd`) installed |

Tests `253-podman-quadlet.bats` (9/9), `254-podman-quadlet-multi.bats` (5/5), `251-system-service.bats` (19/19), and `270-socket-activation.bats` (3/3) pass in both environments.

### 5g: Healthcheck Transient Unit Validation

**VM:** 16/16 pass | **LXC:** 16/16 pass

No failures. For both rootful and rootless: transient timers are created, `ExecStart` references the shim (not the raw snap binary), `LD_LIBRARY_PATH` and all `CONTAINERS_*` config env vars are propagated, and the timer-triggered healthcheck reports healthy status. Tests use a 5-second health interval and wait for the timer to fire — they do not use manual `podman healthcheck run` (which would go through the shim and mask transient unit configuration issues).

---

## Tier 6: Host-Side Impact (VM Only)

**VM:** 29/29 pass

No failures across network integrity (5), library path integrity (3), systemd health (3), reboot survival (9), and snap removal cleanup (9).

---

## Tier 7: Full Upstream BATS Suite

### Root Mode — LXC vs VM

Of the 785 upstream tests, 180 are skipped by the test harness — tests for `pasta` networking, SELinux, checkpoint/restore, and SSH/remote, none of which the snap ships. Of the **605 applicable tests**:

**LXC:** 480 pass (79%) | **VM:** 559 pass (92%) | **VM adapted:** 564 pass (93%)

The VM recovers 79 tests over LXC. The adapted shim pass (respecting pre-existing config env vars) recovers 5 more. The 46 residual VM failures are classified below.

#### LXC-Only Failures (80 tests, resolved in VM)

| Category | Tests Recovered | Cause |
|----------|----------------|-------|
| Quadlet path missing | 44 | Install hook now creates `/usr/libexec/podman/quadlet` symlink |
| Missing `buildah` | 5 | Added to `04_test_setup.sh` |
| LXD kernel limitations | 3 | Full VM kernel eliminates namespace and device restrictions |
| Images / security | 26 | Full VM kernel provides reliable overlay, device access |
| `podman-testing` partial fix | 0 | Binary builds but 11 tests remain infra-limited |
| Networking | 1 | VM network stack more reliable |
| Conmon stderr fix | 1 | `conmon` v2.0.26 fixes `dd` stderr data loss |

#### Failures in Both Environments (46 VM failures)

| Category | Count | Root Cause | Detail |
|----------|-------|------------|--------|
| Snap config override | 27 | Shim force-sets `CONTAINERS_CONF` / `CONTAINERS_STORAGE_CONF` | 5 recoverable via adapted shim; 22 structural |
| `podman-testing` infra | 11 | Binary runs outside snap environment, cannot find snap's `conmon` | `331-system-check.bats` |
| Health check timing | 2 | Wrapper overhead shifts timing assertions | `220-healthcheck.bats` |
| Shell completion | 2 | Completion engine uses snap storage path instead of test's temporary storage | `600-completion.bats` |
| Registry state leakage | 1 | Auth directory conflicts between parallel BATS file runs | `150-login.bats` |
| Container restart timing | 1 | `slirp4netns` restart latency vs `pasta` | `500-networking.bats` |
| Kube health check timing | 1 | `initialDelaySeconds` assertion too tight with wrapper overhead | `700-play.bats` |
| Image store path | 1 | Test reads `/etc/containers/storage.conf` directly; snap redirects this | `010-images.bats` |

#### Adapted Shim Recoveries (5 tests)

These tests pass when the shim respects pre-existing config environment variables:

| Test | File |
|------|------|
| `podman info - json` | `005-info.bats` |
| `podman run --init` | `030-run.bats` |
| `podman build no --dns with --network` | `070-build.bats` |
| `containers.conf read-only` | `800-config.bats` |
| `containers.conf tmpdir` | `800-config.bats` |

#### Structural Failures (22 tests, adapted pass)

18 of 22 share the same root cause: `podman generate systemd` (deprecated) resolves its own binary path at runtime and embeds `/snap/m0x41-podman/x1/usr/bin/podman` in generated unit files. When systemd invokes this path directly, it lacks `LD_LIBRARY_PATH` and config env vars. See [investigations/RCCA-ADAPTED-FAILURES.md](investigations/RCCA-ADAPTED-FAILURES.md).

| Category | Count | Files |
|----------|-------|-------|
| Generated units embed snap binary path | 15 | `250-systemd.bats` (5), `255-auto-update.bats` (10) |
| Quadlet with adapted shim (test artefact) | 2 | `252-quadlet.bats` |
| `runlabel` embeds snap binary path | 1 | `037-runlabel.bats` |
| `podman-testing` cannot find snap conmon | 1 | `005-info.bats` |
| Registry state leakage | 1 | `255-auto-update.bats` |
| Health check timing | 1 | `005-info.bats` |
| `dd` stderr data loss | 0 | **Fixed** — `conmon` upgraded to v2.0.26 |

### Rootless Mode — VM Only

**VM:** 511 pass, 83 skipped, 191 raw failures — but 91 are `pasta` networking tests (not applicable)

The snap bundles `slirp4netns` instead of `pasta` for rootless networking. In root mode, the test harness detects `pasta` as absent and skips these tests. In rootless mode, the same tests attempt to run and fail. These 91 tests are not applicable to the snap and should be excluded from the pass rate.

**Excluding `pasta`: 511/611 applicable tests (84%)**, 100 real failures.

| Category | Count | Root Cause |
|----------|-------|------------|
| `pasta` networking (not applicable) | 91 | `505-networking-pasta.bats` (85) + `500-networking.bats` (6) — skip in root mode, fail in rootless |
| Snap config override | 32 | Same as root mode, plus 5 additional rootless-specific |
| Systemd / Quadlet | 46 | Generated units + deprecated `podman generate systemd` path |
| `podman-testing` infra | 11 | Same as root mode |
| Other | 11 | Health check timing, image store path, registry |

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
