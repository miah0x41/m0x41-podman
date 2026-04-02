# Root Cause and Corrective Action — BATS Test Failures

This document analyses the test failures observed when running the full upstream _Podman_ BATS test suite (tier 7) against the `m0x41-podman` snap in an LXD VM (Ubuntu 24.04, bare-metal KVM). The VM eliminates all LXD container limitations, so every failure documented here is attributable to the snap packaging, missing test infrastructure, or upstream test assumptions.

Tested 2026-04-01. Root mode: 506/785 pass, 102 fail. Rootless mode: 511/785 pass, 191 fail.

## Classification Summary

| Classification | Root Fail | Rootless Fail | Root Cause |
|---------------|-----------|---------------|------------|
| Quadlet path (`$QUADLET`) | 46 | 46 | BATS expects `/usr/libexec/podman/quadlet`; snap installs to `/snap/m0x41-podman/current/usr/libexec/podman/quadlet` |
| Snap config override | 26 | 32 | Snap sets `CONTAINERS_CONF` / `CONTAINERS_STORAGE_CONF` env vars, overriding test harness temp configs |
| Missing `buildah` | 5 | 5 | Tests call `buildah` directly; not bundled in snap and not installed in test VM |
| Missing `podman-testing` binary | 11 | 11 | `331-system-check.bats` requires a Go test helper binary that is not built |
| Missing `pasta` (rootless only) | 0 | 91 | Snap bundles `slirp4netns`; `505-networking-pasta.bats` requires `pasta` |
| Health check timing | 5 | 5 | Race conditions in health check state transitions and journal logging |
| Registry concurrency | 1 | 1 | Shared registry auth directory conflicts across parallel BATS file runs |
| Shell completion | 2 | 2 | Completion uses `$PODMAN` binary name for image resolution; snap wrapper confuses it |
| Container restart timing | 1 | 1 | `podman network after restart` times out — possible `slirp4netns` restart latency |
| Kube play health check | 1 | 1 | Health check `initialDelaySeconds` timing assertion too tight |
| Additional image store path | 1 | 1 | Test reads `/etc/containers/storage.conf` directly; snap redirects this path |

---

## Category 1: Quadlet Path — 46 Failures

### Files Affected

- `252-quadlet.bats` (37 tests)
- `253-podman-quadlet.bats` (9 tests)

### Root Cause

Every test in both files fails in the `setup` function with:

```
Cannot run quadlet tests without executable $QUADLET (/usr/libexec/podman/quadlet)
```

The BATS test harness sets `QUADLET` to `/usr/libexec/podman/quadlet` by default. In the snap, quadlet is at `/snap/m0x41-podman/current/usr/libexec/podman/quadlet`. The `setup` function runs `test -x "$QUADLET"` which fails, and every test cascades.

When tier 5e runs `252-quadlet.bats` via `05_run_tests.sh`, it explicitly exports `QUADLET="${SNAP}/usr/libexec/podman/quadlet"`, which is why tier 5e passes. The tier 7 full suite does not set this.

### Corrective Action

**Option A (recommended)**: Export `QUADLET` in `11_run_bats_full.sh` to point at the snap's quadlet binary. This is a one-line fix that would recover all 46 tests.

```bash
export QUADLET="${SNAP}/usr/libexec/podman/quadlet"
```

**Option B**: Create a symlink at `/usr/libexec/podman/quadlet` pointing to the snap's binary. This mirrors what the install hook does for generators.

**Assessment**: Option A is preferred — it keeps the fix in the test infrastructure without modifying the host. Option B would also be valid if we want quadlet discoverable by third-party tools at the standard path.

### Expected Impact

Recovering these 46 tests will likely reveal a mix of passes and snap-specific failures (similar to the tier 5e results where 69/73 pass). The true failure count for this category is estimated at 4-5 after the fix.

---

## Category 2: Snap Config Override — 26 Failures (Root)

### Files Affected

- `005-info.bats` (3), `030-run.bats` (3), `037-runlabel.bats` (1), `070-build.bats` (1), `250-systemd.bats` (5), `255-auto-update.bats` (10), `500-networking.bats` (1 root / 6 rootless), `800-config.bats` (2)

### Root Cause

The snap must set `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`, and `CONTAINERS_REGISTRIES_CONF` as environment variables so that _Podman_ finds its bundled configuration. The BATS test harness creates temporary directories with its own config files and sets these same env vars — but the snap's values take precedence because the shim at `/usr/local/bin/podman` re-exports them.

Specific manifestations:

- **`005-info.bats`**: `podman info - json` — teardown tries to clean state from a config that was never applied. `CONTAINERS_CONF_OVERRIDE` — test sets `CONTAINERS_CONF` but shim overrides it. `empty string defaults` — test expects a warning when no storage driver is configured.
- **`250-systemd.bats`**: Tests set `CONTAINERS_CONF` to a temp file; shim overrides to snap config. 5 of 16 tests fail.
- **`255-auto-update.bats`**: 10 of 12 tests fail. `setup` function sets config paths that the shim overrides.
- **`800-config.bats`**: Tests expect to control config via env vars.

### Corrective Action

**Option A**: Modify the shim to honour pre-existing `CONTAINERS_CONF` if already set in the environment. This would allow the BATS harness to override. Risk: users who set `CONTAINERS_CONF` to an incomplete config would lose snap defaults.

**Option B**: Modify the shim to use `CONTAINERS_CONF_OVERRIDE` for snap-specific settings instead of overriding `CONTAINERS_CONF` entirely. This is the upstream-recommended approach but requires verifying all snap config options work as overrides.

**Option C (recommended for now)**: Accept these as known snap-specific failures. Document them but do not change the shim's behaviour, as it is correct for user-facing operation. The snap _must_ control its own config paths to function. Consider Option B as a future improvement.

### Assessment

These are a fundamental trade-off of snap packaging. The 26 failures (excluding pasta) represent tests that validate config override mechanisms — the snap intentionally overrides them. This is not a functional regression.

---

## Category 3: Missing `buildah` — 5 Failures

### Files Affected

- `040-ps.bats` test 3 (`podman ps --external`)
- `055-rm.bats` test 3 (`podman rm container from storage`)
- `060-mount.bats` test 7 (`podman mount external container`)
- `140-diff.bats` test 2 (`podman diff with buildah container`)
- `700-play.bats` test 9 (`podman kube play --replace external storage`)

### Root Cause

These tests call `buildah` directly to create "external" containers (containers created by `buildah` that _Podman_ can see in shared storage). `buildah` is not bundled in the snap and is not installed in the test VM.

### Corrective Action

**Option A (recommended)**: Install `buildah` in `04_test_setup.sh`:

```bash
apt-get install -y -qq buildah
```

`buildah` is available in the Ubuntu 24.04 repositories. These tests exercise a legitimate _Podman_ feature (interoperability with `buildah` containers) that the snap should support.

**Option B**: Skip these tests. This would hide a real compatibility gap.

### Expected Impact

All 5 tests should pass once `buildah` is installed — the underlying _Podman_ functionality works; only the test dependency is missing.

---

## Category 4: Missing `podman-testing` Binary — 11 Failures

### File Affected

- `331-system-check.bats` (all 11 tests)

### Root Cause

Every test calls `run_podman_testing`, which invokes `/opt/podman/bin/podman-testing`. This is a Go binary built from the _Podman_ source tree (`cmd/podman-testing/`) that creates deliberately corrupted storage states for `podman system check` to detect. It is not built by default — it requires:

```bash
cd /opt/podman && make podman-testing
```

### Corrective Action

**Option A (recommended)**: Build `podman-testing` in `04_test_setup.sh`:

```bash
cd /opt/podman && make podman-testing
```

This requires Go (already installed) and the _Podman_ source (already cloned). The binary is a small Go build.

**Option B**: Skip `331-system-check.bats`. Acceptable if the build adds too much time.

### Expected Impact

All 11 tests should pass — `podman system check` works correctly; only the test helper that creates bad storage states is missing.

---

## Category 5: Missing `pasta` (Rootless) — 91 Failures

### Files Affected

- `505-networking-pasta.bats` (85 of 86 tests fail, 1 skips)
- `500-networking.bats` (6 additional rootless failures)

### Root Cause

The snap bundles `slirp4netns` for rootless networking because `pasta`/`passt` is not available on the `core22` (Ubuntu 22.04) base snap. In root mode, `505-networking-pasta.bats` tests are skipped (pasta detected as absent). In rootless mode, the tests attempt to run and fail because `slirp4netns` is used instead.

_Podman_ historically used `slirp4netns` as its default rootless networking backend and only switched to `pasta` in v4.x+. The upstream project no longer actively maintains `slirp4netns`-specific BATS tests — the `505-networking-pasta.bats` file replaced the older networking test coverage.

### Corrective Action

**Option A**: Migrate to `core24` base snap, where `pasta` would be available. This is a significant change affecting all components and the `glibc` floor.

**Option B (recommended)**: Accept these as known skips. The snap's `slirp4netns` rootless networking is validated by tier 2 functional tests (DNS, container run, volume mounts). Add a note to the test runner that classifies `505-networking-pasta.bats` failures as expected when `slirp4netns` is in use.

**Option C**: Investigate `slirp4netns`-specific tests. The upstream _Podman_ project removed dedicated `slirp4netns` BATS tests when they migrated to `pasta`. However, the `slirp4netns` project itself (`github.com/rootless-containers/slirp4netns`) has its own test suite that could be adapted. The tests cover port forwarding, MTU, IPv6, and API socket functionality — all relevant to our use case.

### Assessment

The 6 failures in `500-networking.bats` (rootless only) should be investigated separately — they may be related to `slirp4netns` restart latency or port mapping differences, not simply "pasta not available". See Category 8 for one of these.

---

## Category 6: Health Check Timing — 5 Failures

### File Affected

- `220-healthcheck.bats` (tests 1, 5, 9, 10, 11)

### Root Cause

These failures fall into three sub-categories:

1. **Test 1** (`podman healthcheck`): The `_check_health` helper polls for health status transitions. The first health check returns "healthy" but the test expects a specific sequence of events within a tight timing window. The snap's `conmon-wrapper` adds a small overhead to each health check invocation (it must restore `LD_LIBRARY_PATH`), which shifts timing slightly.

2. **Test 5** (`--health-on-failure with interval`): `podman wait` times out after 120 seconds. The container is supposed to be stopped by a failing health check with `--health-on-failure=stop`, but the stop doesn't happen within the timeout. This is a timing/race condition exacerbated by wrapper overhead.

3. **Tests 9, 10** (journal logging, stop container during healthcheck): Health check state assertions are off by one failing streak count, and journal output doesn't contain expected messages. The `conmon-wrapper`'s additional exec layer may cause the health check output to be lost or delayed.

4. **Test 11** (`healthcheck - start errors`): Test creates a fake binary in `$PATH` that should cause a startup failure (exit 126). The snap's shim prepends its own `$PATH`, which may bypass the fake binary.

### Corrective Action

**Investigation needed**: Profile the `conmon-wrapper` overhead and determine if the timing-sensitive tests can be made more tolerant, or if the wrapper introduces a genuine functional difference in health check execution. Tests 1 and 5 are likely timing-only. Tests 9, 10, 11 may indicate real differences in how the wrapper chain affects health check behaviour.

### Priority

Medium. Health checks work functionally (tier 2/3 pass), but the precise state machine behaviour under timing pressure differs from native _Podman_. This could affect production health check reliability under load.

---

## Category 7: Registry Concurrency — 1 Failure

### File Affected

- `150-login.bats` test 14 (`podman containers.conf retry`)

### Root Cause

```
mkdir: cannot create directory '.../podman-bats-registry/auth': File exists
Registry has already been started by another process
```

The `start_registry` helper in the BATS test framework has a concurrency guard that detects when another BATS file has already started the shared test registry. This failure occurs because `150-login.bats` is run after other tests that started a registry, and the cleanup between files is incomplete.

The actual test assertion (`--retry` help text) may also be a snap-specific failure — the snap's `podman pull --help` output may differ from what the test expects.

### Corrective Action

**Option A (recommended)**: Install `apache2-utils` (already done) and ensure the registry setup has clean state between BATS file runs. The `htpasswd` dependency was the original trigger — with it installed, the registry starts correctly on first use, but state leaks between files.

**Option B**: Run `150-login.bats` in isolation to determine if the failure is registry state or a genuine snap difference.

### Priority

Low. `podman login` works correctly in practice (confirmed on host). This is a test infrastructure issue.

---

## Category 8: Shell Completion — 2 Failures

### File Affected

- `600-completion.bats` (tests 1, 2)

### Root Cause

Test 2 reveals the issue clearly:

```
podman __completeNoDesc create quay.io/libpod/testimage:20241011
[Debug] [Error] quay.io/libpod/testimage:20241011: image not known
```

The completion system invokes `podman __completeNoDesc` which runs through the shim. The shim's environment (particularly `CONTAINERS_STORAGE_CONF`) points at the snap's storage config, but the test harness has pre-pulled images into a temporary storage root. The completion engine can't find the image because it's looking in the wrong storage location.

This is a variant of the Category 2 (config override) issue, but it manifests specifically in the completion code path.

### Corrective Action

Same as Category 2 — the shim's config override prevents the completion engine from seeing the test harness's temporary storage. Accept as a known snap-specific limitation.

### Priority

Low. Shell completion works correctly in normal usage.

---

## Category 9: Container Restart Timing — 1 Failure

### File Affected

- `500-networking.bats` test 13 (`podman network after restart`)

### Root Cause

The test creates a container with `--restart always` on a custom network, kills it, and waits for it to restart and serve HTTP. The wait loop times out. With `slirp4netns` as the network backend (instead of `pasta`), container restart may take longer because `slirp4netns` must be re-initialised for each container restart.

### Corrective Action

**Investigation needed**: Determine if `slirp4netns` restart is genuinely slower than `pasta` for this scenario. If so, this is a known `slirp4netns` limitation documented in the upstream project.

### Priority

Low-medium. Container restart with `--restart always` is a production-relevant feature.

---

## Category 10: Kube Play Health Check Timing — 1 Failure

### File Affected

- `700-play.bats` test 25 (`podman kube play healthcheck should wait initialDelaySeconds`)

### Root Cause

The test asserts that a health check transitions from "starting" to "healthy" within a precise number of polling intervals. The health status remains "starting" for too many iterations — the snap's wrapper overhead adds latency to each health check execution, causing the timing assertion to fail.

This is the same root cause as Category 6 (health check timing).

### Corrective Action

Same as Category 6. Profile wrapper overhead.

### Priority

Low. Same root cause as the healthcheck category.

---

## Category 11: Additional Image Store Path — 1 Failure

### File Affected

- `010-images.bats` test 13 (`podman pull image with additional store`)

### Root Cause

```
grep: /etc/containers/storage.conf: No such file or directory
```

The test reads `/etc/containers/storage.conf` directly to configure additional image stores. The snap redirects storage config to `$SNAP/etc/containers/storage.conf` via the `CONTAINERS_STORAGE_CONF` env var. The file doesn't exist at the standard path.

### Corrective Action

This is a variant of Category 2 (config override). The snap's storage config lives inside the snap, not at `/etc/containers/storage.conf`. Accept as a known snap-specific limitation.

### Priority

Low. The snap's storage configuration works correctly for its intended use case.

---

## Corrective Action Summary

| # | Action | Tests Recovered | Effort | Priority |
|---|--------|----------------|--------|----------|
| 1 | Export `QUADLET` env var in `11_run_bats_full.sh` | ~42 (46 minus ~4 snap-specific) | Trivial | High |
| 2 | Install `buildah` in `04_test_setup.sh` | 5 | Trivial | High |
| 3 | Build `podman-testing` in `04_test_setup.sh` | 11 | Low | Medium |
| 4 | Investigate health check wrapper overhead | 5 + 1 kube play | Medium | Medium |
| 5 | Investigate `slirp4netns` restart latency | 1 | Medium | Low |
| 6 | Accept snap config override failures | 0 (documented) | None | — |
| 7 | Accept `pasta` absence as known | 0 (documented) | None | — |

### Quick Wins (Items 1-3)

Implementing items 1-3 would recover an estimated **58 tests** with trivial effort, changing the results from:

- **Root**: 506/785 → ~564/785 (72%)
- **Rootless**: 511/785 → ~569/785 (72%)

### Residual Failures After Quick Wins

After implementing items 1-3, the expected residual failures would be:

| Category | Root | Rootless | Status |
|----------|------|----------|--------|
| Snap config override | ~26 | ~32 | Accepted — fundamental trade-off |
| Quadlet snap-specific | ~4 | ~4 | Subset of config override |
| Health check timing | 5 | 5 | Needs investigation |
| Shell completion | 2 | 2 | Config override variant |
| Registry concurrency | 1 | 1 | Test infra issue |
| Networking | 1 | 6 + 85 pasta | `slirp4netns` differences |
| Image store path | 1 | 1 | Config override variant |
| **Total** | **~40** | **~136** | |
| **Excluding pasta** | **~40** | **~51** | |
