# glinet-dropbear-feed

A signed opkg feed with a current **Dropbear SSH** for GL.iNet routers, built
with OpenWrt's own patches and options, with **ECDSA and FIDO/`sk-` keys
enabled**.

## Why

GL firmware ships an older Dropbear built without ECDSA. On a GL-E5800
(firmware 4.10.4, Dropbear 2024.86) the server advertises only

```
server-sig-algs=<ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-256,ssh-rsa>
```

so `ecdsa-sha2-*` and `sk-ecdsa-sha2-nistp256@openssh.com` (most FIDO security
keys) cannot log in, even when listed in `authorized_keys`. Upstream Dropbear
has also had eight releases since 2024.86, several with security fixes.

## What it builds

| | |
|---|---|
| Source | the upstream release tarball, GPG-verified against the pinned release key (`F7347EF2EE2E07A267628CA944931494F29C6773`, the same fingerprint on the release site and keyserver.ubuntu.com); the pinned version's sha256 also matches OpenWrt's `PKG_HASH` |
| Patches | OpenWrt's full Dropbear patch set, unmodified ([patches/openwrt/SOURCE](patches/openwrt/SOURCE)); `100-pubkey_path.patch` keeps root's keys in `/etc/dropbear/authorized_keys` |
| Options | exactly what OpenWrt's package generates by default ([config/localoptions.h](config/localoptions.h)): ECDSA, Ed25519, FIDO/sk keys, curve25519 + sntrup761 key exchange; no X11, DSS, SHA-1 or CBC |
| Toolchain | `zig cc` with its bundled musl, fully **static**, so one binary per CPU family runs on every GL firmware line regardless of its libc |
| Targets | aarch64 → `aarch64_cortex-a53`; ARMv7 soft-float (Cortex-A9 baseline) → `arm_cortex-a7`, `arm_cortex-a7_neon-vfpv4`, `arm_cortex-a9_vfpv3-d16`, `arm_cortex-a15_neon-vfpv4`; MIPS32r2 soft-float → `mips_24kc`; MIPSel → `mipsel_24kc` |

The package, `glinet-dropbear`, installs the binary as
`/usr/lib/glinet-dropbear/dropbear`. Its postinst runs `glinet-dropbear apply`,
which:

1. checks the new binary runs on this CPU,
2. saves the firmware's `/usr/sbin/dropbear` once (as `dropbear.firmware`),
3. renames the new binary into place and restarts the SSH service,
4. waits until a dropbear running the new file is listening, and otherwise
   **puts the firmware binary back** and restarts again.

The firmware's init script and `/etc/config/dropbear` are not touched, and
`dbclient`, `dropbearkey` and `scp` are symlinks to the same binary.
`opkg remove glinet-dropbear` restores the firmware's binary. A firmware
upgrade also returns to the firmware's own Dropbear, after which you can
reinstall from the feed.

## Install

On the router, as root:

```sh
curl -fsSL https://digitalcybersoft.github.io/glinet-dropbear-feed/setup.sh -o /tmp/setup.sh
sh /tmp/setup.sh --dry-run
sh /tmp/setup.sh
```

The installer picks the device's architecture, downloads `feed.pub`, refuses it
unless its fingerprint is **`4fbc7fcb4ae88dd6`**, installs it as
`/etc/opkg/keys/4fbc7fcb4ae88dd6`, adds the feed, runs a plain `opkg update`
(the feed's `Packages.sig` must verify) and installs `glinet-dropbear`.

Unlike the other glinet-* feeds this one is signed, so **never** use
`--force-signature` with it: that would disable the check. A plain
`opkg update` drops the lists of any unsigned feeds you also use until their
next forced update; that does not affect installed packages.

```sh
glinet-dropbear status    # active / packaged / saved firmware versions
glinet-dropbear revert    # back to the firmware's Dropbear
glinet-dropbear apply     # forward again
```

## How it is built and published

[.github/workflows/build-feed.yml](.github/workflows/build-feed.yml):

1. **resolve**: build the newer of the pinned version and the newest upstream
   release; on the daily schedule skip if that version is already live.
2. **build** (aarch64, arm, mips, mipsel), each:
   - `tools/fetch-source.sh`: download, GPG-verify (and sha256 for the pin)
   - `tools/build.sh`: patches, options, `autoreconf`, static zig build
   - `tools/check-binary.sh`: machine, endianness, static, no VFP/NEON
     on ARM, soft-float on MIPS, required algorithms and `/etc/dropbear`
     compiled in
   - `tools/smoke-test.sh`: under qemu-user on a restrictive CPU model
     (Cortex-A9 without hardware divide; 24Kc without FPU), generate ed25519
     and ECDSA host keys, log in with ed25519 **and** ECDSA keys from OpenSSH,
     and require `sk-ecdsa-sha2-nistp256@openssh.com` and
     `sk-ssh-ed25519@openssh.com` in `server-sig-algs`
3. **publish**: package seven architecture directories, write the indexes,
   sign each `Packages` with `tools/usign.py` (usign-compatible; checked
   against a router's own `/usr/bin/usign`), verify every signature, deploy
   to Pages.

The signing key is stored as the `USIGN_SECRET_KEY` secret of the
`github-pages` environment, which only the publish job uses and which only the
`main` branch can deploy to. The build jobs compile third-party code and never
see it.

Packaging or patch changes for the same upstream version need a higher
`PKG_RELEASE` in [build.conf](build.conf), because opkg only upgrades to a
higher version.

## Build locally

Needs `curl`, `gpg`, `autoconf`, `make`, `python3`; the smoke test also needs
qemu-user binfmt and OpenSSH.

```sh
. ./build.conf
tools/fetch-source.sh $DROPBEAR_VERSION src
export PATH="$(tools/setup-zig.sh):$PATH"
tools/build.sh aarch64 $DROPBEAR_VERSION src out/aarch64
tools/check-binary.sh aarch64 out/aarch64/dropbear
tools/smoke-test.sh aarch64 out/aarch64/dropbear $DROPBEAR_VERSION
```

## Status

- CI checks and qemu smoke tests run for every architecture on every build.
- Not yet verified on real hardware for every architecture, nor with a
  physical FIDO key. The smoke test proves ECDSA logins and that the sk key
  types are advertised, not a hardware-key login.
