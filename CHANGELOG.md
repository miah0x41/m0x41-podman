# Changelog

All notable changes to the `m0x41-podman` snap package are documented here.

Version format: `{upstream_podman_version}+snap{N}` — the suffix tracks snap packaging revisions independent of the upstream _Podman_ release.

## v5.8.8+snap1

Upstream bump to _Podman_ v5.8.8 (rolling up v5.8.7), plus regression tests for the security fixes it carries. The only shipped change is the version string in `scripts/podman-wrapper`; snap behaviour is otherwise unchanged.

**Upstream:** [Podman v5.8.7](https://github.com/containers/podman/releases/tag/v5.8.7), [v5.8.8](https://github.com/containers/podman/releases/tag/v5.8.8) release notes

Both are security releases, and both reach code paths this snap ships:

- **CVE-2025-11395** (v5.8.7): crafted tar archives could overwrite or change attributes of host files when extracted by `podman load` (and other `oci-archive:` consumers) or `podman volume import` ([GHSA-3gcv-x57j-xqxv](https://github.com/podman-container-tools/container-libs/security/advisories/GHSA-3gcv-x57j-xqxv)). The fix confines archive extraction and OCI layout reads to an `os.Root`. v5.8.7 also picks up CVE-2026-79699 and CVE-2026-79705, which upstream does not believe are reachable from the _Podman_ CLI, via Buildah v1.43.4, Common v0.67.2, Image v5.39.3, and Storage v1.62.1.
- **CVE-2026-94603** (v5.8.8): `podman run` treated any image carrying the `io.podman.annotations.checkpoint.runtime.name` annotation as a checkpoint and restored it with the checkpoint's own security configuration, silently discarding user flags such as `--cap-drop=ALL` ([GHSA-2cvf-wqm6-wr9g](https://github.com/podman-container-tools/podman/security/advisories/GHSA-2cvf-wqm6-wr9g)). **Breaking change:** running checkpoint images via `podman run` is removed; it now fails with exit 125 and points at `podman container restore`. Restoring checkpoints requires CRIU, which this snap does not bundle, so no previously working snap workflow is lost.

### Changes

- `snapcraft.yaml` `version` and `source-tag` updated to `5.8.8` / `v5.8.8`
- Both patches apply cleanly against v5.8.8; v5.8.7 and v5.8.8 touch none of the patched files
- Upstream `go.mod` now declares `go 1.26.0` (was `1.25.0`). The bootstrap Go 1.24.2 still builds it, fetching the `go1.26.0` toolchain on demand through the default `GOTOOLCHAIN=auto`; `docs/COMPONENTS.md` and `docs/DEVELOPMENT.md` now say so
- All current-version references across `README.md`, `docs/`, and test scripts bumped from v5.8.6 to v5.8.8. Investigation documents retain their original references

### New Tests

- `security_regressions` in `scripts/05_run_tests.sh`, called from Tier 2 (rootless) and Tier 3 (rootful), adds four checks per mode: checkpoint-annotated images are refused by `podman run`, an oci-archive whose `index.json` symlinks outside the archive is rejected by `podman load` (with a well-formed control that must still load), and `podman volume import` cannot write through an escaping symlink
- The checkpoint and oci-archive checks were run against the v5.8.6 snap first and fail there in both modes, so they catch a regression to a vulnerable build; the volume import check is a confinement guard that v5.8.6 already passed
- `scripts/07_test_setup_multi.sh` installs `tar` on Fedora and CentOS; CentOS 9 Stream omits it and the fixtures need GNU `tar --transform`
- `docs/TESTING.md` documents the checks in a new "Security Regression Checks" section

### Validation

Full 7-tier matrix. Tiers 1–5 in an LXD container reinstalled over v5.8.6 (refresh path), Tiers 1–6 on a fresh LXD VM including reboot survival, multi-distro and wrapper suites on five distros, then Tier 7 on the VM. Results match the v5.8.6 baseline or improve on it: Tier 7 rootless 588/786 (712/786 combined, up from 711), root 585/786 (638/786 combined). The one new root failure, `037-runlabel`, is a harness artefact of running Tier 7 under `systemd-run` without `HOME`, and it passes once `HOME` is set. `docs/TESTING-RESULTS.md` and `docs/TEST-FAILURES.md` are refreshed accordingly, and `docs/TEST-FAILURES.md` now records Tier 4 correctly as 29/31.

## v5.8.6+snap1

Upstream bump to _Podman_ v5.8.6, plus a test-harness fix uncovered while validating it. The only shipped changes are the version string in `scripts/podman-wrapper` and one hardening change in `snap/hooks/install`; snap behaviour is otherwise unchanged.

**Upstream:** [Podman v5.8.6](https://github.com/containers/podman/releases/tag/v5.8.6) release notes

A single-issue security release, and the one issue lands squarely on this snap's _Quadlet_ support:

- **CVE-2026-19730**: `podman quadlet install --replace` opened the destination file without truncating it, so replacing a longer Quadlet with a shorter one left trailing bytes of the original file in place. The resulting hybrid unit could still parse and start, silently running directives the user believed they had removed ([GHSA-fx76-2j3w-2mx6](https://github.com/podman-container-tools/podman/security/advisories/GHSA-fx76-2j3w-2mx6)).

The fix rewrites the install path to write through a temporary file in the destination directory and rename it into place, and to open with `O_EXCL` in the non-replace case so the existence check is no longer racy. The same commit corrects asset-file naming for supported _Quadlet_ extensions. Nothing else changed upstream: the release touches only `pkg/domain/infra/abi/quadlet.go`, its BATS test, the version constant, and packaging metadata.

### Changes

- `snapcraft.yaml` `version` and `source-tag` updated to `5.8.6` / `v5.8.6`
- Both patches (`patches/generate-systemd-binary-path.patch`, `patches/healthcheck-ld-library-path.patch`) apply cleanly against v5.8.6 with no changes; v5.8.6 touches none of the patched files
- All current-version references across `README.md`, `docs/`, and test scripts bumped from v5.8.5 to v5.8.6. The tier 5 fix-attribution comments (#28213, #28409) retain their `v5.8.2` references, since those fixes first landed in that release
- Post-incident investigation documents (`docs/investigations/`) retain their original references, since they describe historical analysis performed against earlier source trees
- `docs/TESTING-RESULTS.md` and `docs/TEST-FAILURES.md` refreshed with the v5.8.6 re-validation

### Test Harness Fix

Validation of this release surfaced a long-standing race in the test scripts that produced spurious failures, most visibly `rootless healthcheck transient timer not found` in tier 5. Under `set -o pipefail`, `grep -q` exits the moment it matches and SIGPIPEs a producer that is still writing; the pipeline then reports the producer's `141` instead of grep's `0`, turning a successful match into a reported failure. Whether it bites depends on which process finishes first, so it fired intermittently and only behind slow producers such as `su -` into `systemctl --user`.

The defect is confined to the harness — the healthcheck itself was verified working in every failing run — and predates this release, failing more often on v5.8.5 (5 of 9 runs) than on v5.8.6 (7 of 17). Full analysis in [`docs/investigations/RCCA-PIPEFAIL-GREPQ.md`](docs/investigations/RCCA-PIPEFAIL-GREPQ.md).

- `qgrep`/`qgrepE` helpers (using `grep -c`, which reads to EOF) replace `grep -q` at all 49 piped call sites in `scripts/05_run_tests.sh`, `scripts/10_wrapper_tests.sh`, and `scripts/upgrade-snap.sh`
- `snap/hooks/install` uses a `case` pattern match instead of piping into `grep -q`
- `scripts/08_wrapper_test_launch.sh` waits up to 180s rather than 60s for container networking, which was timing out when five distros launch at once on a loaded host
- `scripts/09_wrapper_test_setup.sh` retries `snap install` around seeding instead of letting `snap wait system seed.loaded` fail silently, fixing `device not yet seeded` on images where snapd ships preinstalled
- Tier 5 re-run 6 times per version after the fix: 0 failures, against 12 failures in the 26 runs before it
- `docs/TESTING.md` gains a "Writing Assertions" section covering the `grep -q` rule, and records that tier 6 must run before tier 7 (or on a separate VM) because the upstream BATS suite leaves failed transient units that tier 6's 6c assertion attributes to the snap

## v5.8.5+snap1

Upstream bump to _Podman_ v5.8.5 (rolling up v5.8.3, v5.8.4, and v5.8.5). No packaging changes.

**Upstream:** [Podman v5.8.3](https://github.com/containers/podman/releases/tag/v5.8.3), [v5.8.4](https://github.com/containers/podman/releases/tag/v5.8.4), [v5.8.5](https://github.com/containers/podman/releases/tag/v5.8.5) release notes

These are security and bug-fix releases. Two of the security fixes are directly relevant to this snap, which ships the full `podman build` and image-run paths:

- **CVE-2026-44517** (v5.8.3): a `Containerfile` using `ADD` or `COPY` against a malicious Git repository or tar archive could write files outside the build context. Fixed by updating the vendored Buildah to v1.43.2 ([GHSA-49p4-px3h-rq49](https://github.com/podman-container-tools/buildah/security/advisories/GHSA-49p4-px3h-rq49)).
- **CVE-2026-57231** (v5.8.4): a malicious image with malformed `Env` entries could leak host environment variables into containers, including via the `*` glob operator ([GHSA-4hq8-gpf5-8p68](https://github.com/podman-container-tools/podman/security/advisories/GHSA-4hq8-gpf5-8p68)).

The remaining upstream changes have no effect on this snap: the `golang.org/x/crypto` bump to v5.8.4 (CVE-2026-39830, CVE-2026-42508) is a vendored-dependency refresh, and the v5.8.5 fix for `podman machine` VMs shutting down on Mac/libkrun targets a component this Linux-only snap does not ship. The v5.8.4 remote-client `podman save -f oci-dir`/`docker-dir` fix carries over with the full binary but changes nothing in packaging.

### Changes

- `snapcraft.yaml` `version` and `source-tag` updated to `5.8.5` / `v5.8.5`
- Both patches (`patches/generate-systemd-binary-path.patch`, `patches/healthcheck-ld-library-path.patch`) apply cleanly against v5.8.5 with no changes; v5.8.3–v5.8.5 touch none of the patched files
- All current-version references across `README.md`, `docs/`, and test scripts bumped from v5.8.2 to v5.8.5. The tier 5 fix-attribution comments (#28213, #28409) retain their `v5.8.2` references, since those fixes first landed in that release
- Post-incident investigation documents (`docs/investigations/`) retain their original references, since they describe historical analysis performed against earlier source trees
- `docs/TESTING-RESULTS.md` and `docs/TEST-FAILURES.md` refreshed with the v5.8.5 re-validation (full 7-tier matrix; Tier 7 BATS root 585→638/786 and rootless 587→711/786 combined)

## v5.8.2+snap1

Upstream bump to _Podman_ v5.8.2. No packaging changes.

**Upstream:** [Podman v5.8.2 release notes](https://github.com/containers/podman/releases/tag/v5.8.2)

Upstream v5.8.2 is a security and bug-fix release. The security fix (CVE-2026-33414, `podman machine init --image` Powershell injection on Windows/Hyper-V) does not affect this snap, which targets Linux only and does not ship `podman machine`. The user-visible bug fixes relevant to this snap are:

- `unless-stopped` containers now restart correctly after reboot when `podman-restart.service` is enabled ([#28152](https://github.com/containers/podman/issues/28152))
- Quadlet `.container` files with `Entrypoint=` (empty value) now correctly clear the image's default entrypoint ([#28213](https://github.com/containers/podman/issues/28213))
- Quadlet `.container` files with `HealthCmd` values containing embedded double-quotes now produce functional healthchecks ([#28409](https://github.com/containers/podman/issues/28409))

### Changes

- `snapcraft.yaml` `version` and `source-tag` updated to `5.8.2` / `v5.8.2`
- `patches/generate-systemd-binary-path.patch` regenerated against v5.8.2 (applies cleanly with zero fuzz; no functional change). `patches/healthcheck-ld-library-path.patch` is unchanged
- Tier 5 regression suite gains two Quadlet dry-run assertions covering the `Entrypoint=` clearing fix (#28213) and the `HealthCmd` double-quote fix (#28409). Both assertions were validated against the v5.8.1+snap2 release artifact to confirm they fail on the unfixed build
- All current-version references across `README.md`, `docs/`, and test scripts bumped from v5.8.1 to v5.8.2. Post-incident investigation documents (`docs/investigations/`) retain their original v5.8.1 references, since they describe historical analysis performed against that source tree

## v5.8.1+snap2

Supply-chain integrity for release artifacts.

Every release now includes three verification mechanisms so that users can confirm the snap they downloaded is authentic, untampered, and built by this repository's GitHub Actions workflow:

| Measure | Asset | What it proves |
|---------|-------|----------------|
| SHA256 checksum | `.sha256` | The file was not corrupted or modified after publication |
| Cosign keyless signature | `.cosign-bundle` | The file was signed by this repository's CI using Sigstore OIDC — no long-lived keys |
| SLSA provenance attestation | GitHub-native | The file was built by a specific workflow, from a specific commit, in this repository |

### Changes

- Build workflow generates SHA256 checksum, cosign keyless signature bundle, and SLSA provenance attestation for every release
- All three verification artifacts are uploaded alongside the snap as release assets
- README includes a Verification section with download and verification commands
- No secrets or long-lived keys required — cosign uses GitHub's OIDC identity, attestations use the built-in workflow token

## v5.8.1+snap1

Initial release.

**Upstream:** [Podman v5.8.1 release notes](https://github.com/containers/podman/releases/tag/v5.8.1)

### Bundled Components

| Component | Version | Source |
|-----------|---------|--------|
| Podman (with Quadlet) | v5.8.1 | Built from source |
| crun | 1.19.1 | Built from source |
| conmon | 2.0.26 | Built from source |
| netavark | 1.14.1 | Pre-built binary |
| aardvark-dns | 1.14.0 | Pre-built binary |
| catatonit, fuse-overlayfs, slirp4netns, iptables | core22 | Staged from Ubuntu 22.04 |

### Features

- Classic confinement snap on `core22` (Ubuntu 22.04) base
- Rootless and rootful operation
- Full Quadlet (systemd integration) support with auto-registered generators
- Install hook places `podman` on PATH at `/usr/local/bin/podman`
- Bundled man pages, systemd socket units, and container policy
- Tested across Ubuntu 22.04, Ubuntu 24.04, Debian 12, CentOS 9 Stream, and Fedora 43

### Patches Applied

- **Healthcheck LD_LIBRARY_PATH** — propagates `LD_LIBRARY_PATH` into healthcheck transient units so that snap-bundled libraries are visible to `conmon` and `crun` when systemd executes healthcheck timers
- **Generate systemd binary path** — overrides the binary path in `podman generate systemd` output via `PODMAN_BINARY` so generated units reference the `/usr/local/bin/podman` shim rather than the snap-internal path
