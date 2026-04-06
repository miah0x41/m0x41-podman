# RCCA #3: systemd-networkd / systemd-resolved SEGV — Snap Library Path Poisoning

**Date of Incident:** 2026-03-31 ~14:57 UTC (boot -1), persisting through boot 0 (~15:52 UTC)
**Date of Investigation:** 2026-03-31
**Date of Resolution:** 2026-03-31 ~15:59 UTC
**Environment:** Hetzner vServer (KVM), Ubuntu 24.04.4 LTS (Noble Numbat)
**Hostname:** chatty-cheetah
**Related:** RCCA #1 (systemd-networkd SIGSEGV, 2026-03-30), RCCA #2 (GRUB hang, 2026-03-31)

---

## 1. Symptom

After rebooting from the RCCA #2 rescue session, `systemd-networkd` and
`systemd-resolved` crash immediately on startup with SIGSEGV (signal 11).
Both services hit the systemd restart limit (5 attempts) within ~1 second and
enter a failed state. No DHCP, no routing, no DNS. The server is unreachable
via SSH until networking is manually configured with `ip addr`, `ip route`, and
a static `/etc/resolv.conf`.

This persisted across two reboots:
- Boot -1 (kernel 6.8.0-101, no `clearcpuid=avx512f`): crashed at libc offset
  `0x173136` (AVX-512 code path)
- Boot 0 (kernel 6.8.0-106, with `clearcpuid=avx512f`): crashed at libc offset
  `0x16302b` (AVX2 code path)

Both crashes are NULL pointer dereferences in glibc string functions, differing
only in which IFUNC-dispatched implementation is selected.

---

## 2. Root Cause

### 2.1 Primary Cause: `podman-snap.conf` Polluting System-Wide Linker Path

The `m0x41-podman` snap's install hook
(`/snap/m0x41-podman/current/snap/hooks/install`, section 3) creates:

```
/etc/ld.so.conf.d/podman-snap.conf
```

containing:

```
/snap/m0x41-podman/current/usr/lib/x86_64-linux-gnu
/snap/m0x41-podman/current/lib/x86_64-linux-gnu
```

The hook then runs `ldconfig`, which registers these paths in the system-wide
dynamic linker cache. Because `podman-snap.conf` sorts alphabetically before
`x86_64-linux-gnu.conf` (which contains the system library paths), the snap's
libraries take **precedence over system libraries** for every process on the
host.

The snap ships `libseccomp.so.2.5.3` (BuildID `3f79a2bf`), while the system has
`libseccomp.so.2.5.5` (BuildID `ebbca394`). Both `systemd-networkd` and
`systemd-resolved` link against `libseccomp.so.2`. With the poisoned cache, they
load the snap's 2.5.3 instead of the system's 2.5.5.

The snap's libseccomp was built for a different environment (likely Ubuntu 22.04,
given the snap's other library versions). When used by the host's systemd
(255.4-1ubuntu8.12, built against the host's 24.04 libraries), it causes a NULL
pointer to be passed to a glibc string function during seccomp filter setup,
resulting in an immediate SEGV.

### 2.2 Evidence: Removal Fixes the Crash

```
# Before fix — snap libseccomp loaded:
$ ldconfig -p | grep libseccomp
  libseccomp.so.2 => /snap/m0x41-podman/current/usr/lib/x86_64-linux-gnu/libseccomp.so.2
  libseccomp.so.2 => /lib/x86_64-linux-gnu/libseccomp.so.2

$ systemctl restart systemd-networkd   # → SEGV

# Fix applied:
$ mv /etc/ld.so.conf.d/podman-snap.conf /etc/ld.so.conf.d/podman-snap.conf.disabled
$ ldconfig

# After fix — system libseccomp loaded:
$ ldconfig -p | grep libseccomp
  libseccomp.so.2 => /lib/x86_64-linux-gnu/libseccomp.so.2

$ systemctl restart systemd-networkd   # → active (running), DHCP acquired
$ systemctl restart systemd-resolved   # → active (running), DNS serving
```

### 2.3 Why RCCA #2's "Boot 0" Worked (And Masked the Real Cause)

RCCA #2 reported that boot -2 (Mar 31 10:44–14:12) operated normally with
systemd .12 and `clearcpuid=avx512f`, concluding that the .12 downgrade "fully
resolved" the host SEGV. This conclusion was wrong. The real reason boot -2
worked:

**The `ldconfig` cache was rebuilt during the rescue chroot — where the snap
filesystem was not mounted.**

Timeline:
1. During the rescue session (between boots -3 and -2), systemd packages were
   downgraded via `dpkg -i` inside a chroot at `/mnt`. Package triggers ran
   `ldconfig` inside the chroot.
2. In the rescue chroot, `/snap/m0x41-podman/current/` was not mounted, so
   even though `podman-snap.conf` pointed to those paths, `ldconfig` found no
   libraries there and excluded them from the cache.
3. Boot -2 started at 10:44:25. `ldconfig.service` was **skipped** ("no trigger
   condition checks were met"). The cache from the rescue chroot — without snap
   libraries — was used.
4. `systemd-networkd` started at 10:44:28, loaded the system's libseccomp
   2.5.5, and ran correctly.
5. Corroborating evidence: at 10:44:33, the snap's `crun` failed with
   `libyajl.so.2: cannot open shared object file` — proving the ldconfig cache
   did NOT include snap library paths at boot time.
6. At 11:11:14, charlie installed snap revision x2. The install hook ran
   `ldconfig`, re-poisoning the cache with snap library paths. But networkd was
   already running and was not affected.
7. At 14:12:39, charlie rebooted. On boot -1, the poisoned cache was used from
   the start, and networkd crashed.

Neither the systemd .12 downgrade nor `clearcpuid=avx512f` had any effect on
the crash. The `.12` vs `.14` distinction is irrelevant — both versions crash
when loaded with the snap's libseccomp. The `clearcpuid=avx512f` parameter only
changes which glibc IFUNC implementation handles the NULL pointer (AVX-512 at
offset `0x173136` vs AVX2 at `0x16302b`); both crash.

### 2.4 The Snap Install Hook Design Flaw

The hook's comment explains the intent:

```bash
# ---------- 3. Register snap libraries with ldconfig ----------
# Child processes (conmon -> crun) don't inherit LD_LIBRARY_PATH from
# the wrapper or shim. Register the snap's library directory system-wide.
```

The snap's `/usr/local/bin/podman` shim already sets `LD_LIBRARY_PATH` for
podman itself. But child processes spawned by the container runtime (conmon,
crun) do not inherit this variable, so they can't find snap-bundled libraries
like `libyajl.so.2`.

The hook "fixes" this by registering the snap's entire library directory in the
**system-wide** linker configuration. This is a dangerous approach because:

1. It affects **every process** on the system, not just podman and its children
2. Snap libraries may shadow system libraries with incompatible versions
3. It persists across reboots and is re-applied on every `snap install`/`refresh`
4. The linker uses the first matching library found, with no version negotiation

The correct approaches would be:
- Set `RPATH`/`RUNPATH` in the snap's conmon and crun binaries at build time
- Use wrapper scripts for conmon and crun that set `LD_LIBRARY_PATH`
- Statically link the required libraries into the snap's binaries
- At minimum, create a separate `ld.so.conf.d` file that is loaded AFTER system
  paths (e.g., `zz-podman-snap.conf`) and only includes libraries not provided
  by the system

---

## 3. Crash Signature Comparison Across Boots

| Property | Boot -3 (.14, no clrcpu) | Boot -1 (.12, no clrcpu) | Boot 0 (.12, clrcpu) |
|----------|--------------------------|--------------------------|----------------------|
| Kernel | 6.8.0-101 | 6.8.0-101 | 6.8.0-106 |
| systemd | 255.4-1ubuntu8.14 | 255.4-1ubuntu8.12 | 255.4-1ubuntu8.12 |
| `clearcpuid=avx512f` | No | No | Yes |
| Snap libseccomp loaded | No (clean cache) | Yes (poisoned cache) | Yes (poisoned cache) |
| Crash offset in libc | 0x173136 | 0x173136 | 0x16302b |
| Instruction prefix | EVEX (AVX-512) | EVEX (AVX-512) | VEX (AVX2) |
| Fault address | 0x0 (NULL) | 0x0 (NULL) | 0x0 (NULL) |
| **networkd status** | **SEGV** | **SEGV** | **SEGV** |

| Property | Boot -2 (.12, clrcpu) | Boot 0 after fix |
|----------|----------------------|------------------|
| Kernel | 6.8.0-101 | 6.8.0-106 |
| systemd | 255.4-1ubuntu8.12 | 255.4-1ubuntu8.12 |
| Snap libseccomp loaded | **No** (rescue cache) | **No** (conf disabled) |
| **networkd status** | **Running** | **Running** |

The only variable that correlates with the crash is whether the snap's
libseccomp is in the linker cache.

### 3.1 Reassessment of RCCA #1

RCCA #1 attributed the original crash (boot -3, Mar 30) to the USN-8119-1
security update (systemd .12 → .14). However, boot -3's `ldconfig` was also
skipped, and the cache at that time was from boot -4 (Mar 27–30). During boot -4,
the snap x1 was installed (Mar 25) and `ldconfig` was run by the install hook,
poisoning the cache. Boot -4 ran for 3 days without networkd crashing because
it was booted BEFORE the snap install and networkd was already running.

When the USN-8119-1 update was applied during boot -4, systemd was restarted,
picking up the poisoned cache. It is possible that the .14 update coincidentally
changed systemd's libseccomp usage in a way that triggered the incompatibility,
or that networkd was restarted for the first time after the cache was poisoned.

The true root cause across ALL crashes (RCCA #1, #2, #3) is the snap library
poisoning. The systemd version and AVX-512 instruction set were never factors.

---

## 4. Timeline

| Time (UTC) | Event |
|------------|-------|
| **2026-03-25 18:10** | **`podman-snap.conf` created** by snap x1 install hook. `ldconfig` run. System-wide linker cache now includes snap library paths. |
| Mar 25–27 | Boot -7 to -5: Various reboots. networkd behavior during these boots is unclear. |
| Mar 27–30 | Boot -4: 3-day session. Snap x1 active. networkd runs (started before snap install on Mar 25). USN-8119-1 applied during this session. |
| **Mar 30 10:50** | **Boot -3**: networkd crashes (SEGV). Cache poisoned from boot -4. Attributed to USN-8119-1 (RCCA #1). |
| Mar 30–31 | Rescue session: systemd downgraded .14→.12. `ldconfig` runs in chroot without snap mounts → clean cache. |
| **Mar 31 10:44** | **Boot -2**: networkd works. Clean ldconfig cache (no snap libs). |
| Mar 31 11:11 | Snap x2 installed. Install hook runs `ldconfig` → cache re-poisoned. |
| Mar 31 14:12 | Charlie runs `sudo reboot`. |
| **Mar 31 14:57** | **Boot -1**: networkd crashes. Poisoned cache used from start. GRUB also had visibility issues (RCCA #2). |
| Mar 31 ~15:20 | Rescue session: GRUB fixed, `clearcpuid=avx512f` added. |
| **Mar 31 15:52** | **Boot 0**: networkd still crashes despite `clearcpuid=avx512f`. |
| **Mar 31 15:59** | **Fix applied**: `podman-snap.conf` disabled, `ldconfig` rebuilt. networkd and resolved start immediately. |

---

## 5. Corrective Actions

### 5.1 Applied: Disable `podman-snap.conf` (Immediate)

```bash
mv /etc/ld.so.conf.d/podman-snap.conf /etc/ld.so.conf.d/podman-snap.conf.disabled
ldconfig
systemctl restart systemd-networkd systemd-resolved
```

Both services started successfully. DHCP acquired 159.69.48.207/32, DNS
resolving via Hetzner nameservers.

### 5.2 Applied: `clearcpuid=avx512f` in GRUB

Added to `GRUB_CMDLINE_LINUX` in `/etc/default/grub` and `update-grub` run.
While this was NOT the fix for the networkd crash, it remains a reasonable
defensive measure until the container segfaults (separate from this issue)
are investigated.

### 5.3 Recommended: Prevent Snap From Re-Poisoning on Refresh

The snap install hook runs on both `snap install` and `snap refresh`. Any
future snap refresh will recreate `podman-snap.conf` and re-poison the cache.

**Option A — Block the file with dpkg-divert (preferred):**

```bash
# Delete the disabled file
rm /etc/ld.so.conf.d/podman-snap.conf.disabled

# Create an immutable empty file to prevent the hook from recreating it
touch /etc/ld.so.conf.d/podman-snap.conf
chattr +i /etc/ld.so.conf.d/podman-snap.conf
ldconfig
```

**Option B — Fix the snap install hook:**

Edit `/snap/m0x41-podman/current/snap/hooks/install` to replace section 3 with
a scoped solution. Since snaps are read-only squashfs, this requires rebuilding
the snap. Replace:

```bash
cat > /etc/ld.so.conf.d/podman-snap.conf <<EOF
${SNAP_CURRENT}/usr/lib/x86_64-linux-gnu
${SNAP_CURRENT}/lib/x86_64-linux-gnu
EOF
ldconfig
```

With wrapper scripts for conmon and crun that set `LD_LIBRARY_PATH`, or rebuild
those binaries with appropriate `RPATH` values.

### 5.4 Recommended: Restore Podman Functionality

With `podman-snap.conf` disabled, the snap's `crun` and `conmon` will not find
`libyajl.so.2` and other snap-bundled libraries. To restore podman without
the system-wide poisoning:

**Option A — Install the missing libraries as system packages:**

```bash
sudo apt install libyajl2
```

This provides `libyajl.so.2` at the system path. The other snap-bundled
libraries (`libassuan`, `libgpgme`, `libksba`, `libslirp`, etc.) are either
already installed system-wide or not needed by crun/conmon.

**Option B — Symlink only the needed libraries:**

```bash
# Only libyajl is missing from the system
ln -s /snap/m0x41-podman/current/usr/lib/x86_64-linux-gnu/libyajl.so.2 \
      /usr/local/lib/x86_64-linux-gnu/libyajl.so.2
ldconfig
```

This adds only libyajl without pulling in the snap's libseccomp.

### 5.5 Recommended: Resolve Remaining netavark Issue

The "could not find netavark" error from RCCA #2 Section 7.2 persists
independently. Either:

```bash
sudo apt install netavark
```

Or configure the snap's `containers.conf` with `helper_binaries_dir` pointing
to the snap's bundled netavark.

### 5.6 Recommended: Review systemd Package Holds

The systemd .12 downgrade and package holds from RCCA #1 are no longer needed
since the crash was caused by the snap's libseccomp, not the systemd version.
Once the snap library issue is permanently resolved, consider:

```bash
sudo apt-mark unhold systemd libsystemd-shared libsystemd0 systemd-resolved \
    systemd-timesyncd udev libnss-systemd libpam-systemd libudev1 systemd-dev \
    systemd-sysv
sudo apt-mark unhold linux-image-6.8.0-106-generic
sudo apt update && sudo apt upgrade
```

This will allow normal security updates to resume. **Test on a non-production
window first** — the snap issue should be permanently fixed (5.3) before
unholding, to confirm that current systemd versions work with the system
libseccomp.

---

## 6. Post-Reboot Verification Checklist

```bash
# 1. Verify podman-snap.conf is still disabled/blocked
ls -la /etc/ld.so.conf.d/podman*
# Should show .disabled or immutable empty file

# 2. Verify ldconfig cache has no snap paths
ldconfig -p | grep snap
# Should return nothing

# 3. Verify systemd services
systemctl status systemd-networkd systemd-resolved systemd-timesyncd

# 4. Verify networking
ip addr show eth0          # Should show 159.69.48.207/32
ip route show              # Should show default via 172.31.1.1
resolvectl status eth0     # Should show DNS servers

# 5. Check for segfaults
journalctl -b -k | grep segfault
# Host services should have zero segfaults

# 6. Verify SSH
ss -tlnp | grep 62226

# 7. Test podman (expect libyajl error until 5.4 is applied)
sudo -u charlie /usr/local/bin/podman ps 2>&1
```

---

## 7. Lessons Learned

1. **Snap classic confinement is not confined.** A classic snap's install hook
   runs as root with full filesystem access. It can (and did) modify
   system-wide configuration that affects every process, including PID 1's
   children. Classic snaps should be audited before installation.

2. **`ldconfig` cache state is invisible.** The poisoned library path was not
   apparent from `dpkg -l`, `apt-mark showhold`, or systemd service status.
   Only `ldd <binary>` or `ldconfig -p` revealed the wrong library being
   loaded. When debugging SEGVs, always check `ldd` output.

3. **Coincidental fixes mask root causes.** The rescue chroot's `ldconfig`
   accidentally produced a clean cache, making the .12 downgrade appear to
   be the fix. This led to two additional RCCA cycles chasing the wrong
   cause (systemd version, AVX-512 instructions, GRUB configuration).

4. **One-variable-at-a-time debugging.** Boot -2 changed three variables
   simultaneously (systemd version, clearcpuid, and unknowingly the ldconfig
   cache). The successful boot was attributed to the intentional changes
   rather than the accidental one.
