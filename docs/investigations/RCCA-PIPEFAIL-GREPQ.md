# RCCA #5: `pipefail` + `grep -q` Race Causes Spurious Test Failures

**Date of Investigation:** 2026-08-15
**Environment:** LXD VMs (Ubuntu 24.04), _Podman_ v5.8.5 and v5.8.6 snaps
**Related:** [HEALTHCHECK_ISSUES.md](HEALTHCHECK_ISSUES.md) (the assertion this first surfaced in)

---

## 1. Symptom

During the v5.8.6 validation, tier 5 intermittently reported:

```
--- rootless healthcheck: transient timer exists ---
  FAIL: rootless healthcheck transient timer not found
```

The failure was baffling in three ways:

1. Every **subsequent** assertion in the same block passed — including `ExecStart references shim`, all four config env var checks, and `timer-triggered status is healthy`. Those all derive from the *same* `systemctl --user list-units` lookup that had supposedly just failed ten times.
2. It never reproduced in isolation. A standalone probe replicating the block hit on the first poll in 8 of 8 runs, on both a clean VM and the VM where the suite had just failed.
3. It was not correlated with host load. It failed on an idle box and passed under heavy load.

## 2. Investigation

An external watcher, running as root and polling every 250 ms, recorded two independent signals while the unmodified suite ran: the transient unit files systemd had on disk (`/run/user/<uid>/systemd/transient/`), and what an identical `su - podtest -c "systemctl --user list-units"` query returned.

Correlating a failing iteration against the watcher:

| Time | Event |
|------|-------|
| 22:18:59.793 | test begins `transient timer exists` check |
| 22:18:59.843 | watcher sees the timer **on disk** (+50 ms) |
| 22:18:59.920 | watcher's query **returns the timer** (+127 ms) |
| 22:19:10.591 | test **FAILS** after 10 polls |
| 22:19:21.678 | timer removed by the test's own cleanup |

The timer was present, queryable, and carried the exact container ID the assertion was grepping for (verified by logging `HC_RL_ID` and comparing it against the on-disk unit name) for the entire 10.8 s polling window.

Successive hypotheses were each eliminated by measurement:

| Hypothesis | Refuted by |
|-----------|-----------|
| Timer created late | On disk within ~150 ms of container start, every run |
| User manager restarted / session teardown | `Linger=yes`, manager `active`, `ActiveEnterTimestamp` unchanged, 0 flaps over 40 polls |
| Test searching for a stale or wrong ID | `HC_RL_ID` matched the on-disk unit name exactly, `len=64` |
| Output truncation hiding the unit name | Watcher grepping by description and by ID prefix always agreed |
| `su`/`systemctl` erroring, masked by `2>/dev/null` | Stderr captured to a file during failures: empty, and each poll took only ~70 ms |
| The `run_as_testuser` form itself | Watcher running the byte-identical form hit while the test missed |

Capturing the test's own stdout with `tee` (which preserves the pipeline shape) gave the answer:

```
### failing iteration
1 lines=3 hit=1        <-- pattern present, output truncated at 3 lines
...
10 lines=3 hit=1
  FAIL: rootless healthcheck transient timer not found

### passing iteration
1 lines=3  hit=1
2 lines=10 hit=1       <-- full 10-line listing
  PASS: rootless healthcheck transient timer exists
```

On failing polls the pattern **was** matched, and the captured output was truncated — the signature of `grep -q` exiting early and killing the producer mid-write.

## 3. Root Cause

`scripts/05_run_tests.sh` sets `set -euo pipefail` (line 8). The assertion was:

```bash
run_as_testuser "systemctl --user list-units --type=timer --no-pager" 2>/dev/null \
    | grep -q "${HC_RL_ID:0:12}"
```

The failure sequence:

1. `grep -q` exits `0` the moment it matches, closing the read end of the pipe.
2. The producer — `su -` wrapping `systemctl --user` — is still writing. Its next `write()` gets `EPIPE`/`SIGPIPE`, so it exits `141`.
3. `pipefail` makes the pipeline's exit status the rightmost **non-zero** status, i.e. `141` rather than grep's `0`.
4. The `if` therefore evaluates false, and a **successful match is reported as a failure**.

The race is won or lost on whether the producer finishes writing before `grep -q` exits. Short output, a warm cache, or a fast producer means the producer has already exited and no signal is delivered — so the assertion passes. A slow multi-process producer such as `su -` into `systemctl --user` is still writing, so it fails. This is why the bug required full tier 5 context (which slows the user manager) and why every reduced reproduction passed.

Minimal reproduction:

```bash
set -euo pipefail
for i in $(seq 1 200); do
    if seq 1 200000 | grep -q "^7$"; then hits=$((hits+1)); else misses=$((misses+1)); fi
done
# pipefail:    matched=0   spurious_failures=200
# no pipefail: matched=200 spurious_failures=0
```

This also explains each earlier contradiction. The external watcher used `grep -c`, which reads to EOF and never SIGPIPEs the producer, so it always saw the timer. Instrumented variants that captured stdout into a variable removed the pipe entirely and never reproduced the failure — the instrument was perturbing what it measured. And the "extended poll" after a failure always found the timer, because by then the producer's output was cached and fast enough to complete first.

## 4. Scope

The defect is in the **test harness**, not the snap. In every failing run the healthcheck itself was verified working: the transient timer was created within ~150 ms, `ExecStart` pointed at `/usr/local/bin/podman` (the shim), `LD_LIBRARY_PATH` and all three `CONTAINERS_*` variables were propagated onto the transient unit, and the container reached `healthy`.

It is also **not** a v5.8.6 regression. Measured failure rates for the same assertion, unmodified script, identical clean VMs:

| Snap | Tier 5 runs | Failures |
|------|------------|----------|
| v5.8.5+snap1 (released) | 9 | 5 (56%) |
| v5.8.6 | 17 | 7 (41%) |

The published v5.8.5 baseline recorded this assertion as passing simply because those runs won the race.

Affected call sites, all using `producer | grep -q` under `pipefail`:

| File | Sites | Risk |
|------|-------|------|
| `scripts/05_run_tests.sh` | 45 | High — several wrap `su -`/`systemctl`/`podman` producers |
| `scripts/10_wrapper_tests.sh` | 2 | Low — `echo` producers, output fits the pipe buffer |
| `scripts/upgrade-snap.sh` | 2 | Low — `readlink` producers |
| `snap/hooks/install` | 1 | Cosmetic — falls through to an equivalent check |

`scripts/podman-wrapper` and `snap/hooks/remove` use the same idiom but do **not** set `pipefail`, so they are unaffected.

## 5. Corrective Action

A helper replaces `grep -q` in piped assertions. `grep -c` reads stdin to EOF, so the producer never receives `SIGPIPE`, while the exit status remains `0` on match and `1` on no match:

```bash
qgrep()  { grep -c  -e "$1" >/dev/null; }
qgrepE() { grep -cE -e "$1" >/dev/null; }
```

Applied to all 49 piped sites across `05_run_tests.sh`, `10_wrapper_tests.sh`, and `upgrade-snap.sh`. In `snap/hooks/install` the single site became a `case` pattern match, avoiding the subshell entirely.

### Verification

Tier 5 was re-run 6 times on each VM with the corrected script:

| Snap | Runs | Failures before fix | Failures after fix |
|------|------|--------------------|--------------------|
| v5.8.5+snap1 | 6 | 5 of 9 | 0 |
| v5.8.6 | 6 | 7 of 17 | 0 |

## 6. Lessons

- `set -o pipefail` and `grep -q` are individually reasonable and jointly a race. Any `producer | grep -q` under `pipefail` can convert a match into a reported failure, with the probability set by how long the producer keeps writing.
- Discarding stderr (`2>/dev/null`) on an assertion's producer removes the evidence that would distinguish "condition false" from "command failed". The stderr here was empty, which was itself the clue that ruled out a whole class of explanations.
- Instrumentation that changes a pipeline into a command substitution changes the thing being measured. The failure only reappeared once the instrument (`tee`) preserved the pipeline's shape.
- An assertion whose downstream dependants all pass is evidence about the assertion, not the system under test.
