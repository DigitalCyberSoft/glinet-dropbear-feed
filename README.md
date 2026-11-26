# glinet-dropbear-feed

A signed opkg feed with a current **Dropbear SSH** for GL.iNet routers, built
with OpenWrt's own patches and options, with **ECDSA and FIDO/`sk-` keys
enabled**.

## In short

- GL.iNet firmware ships an older SSH server (Dropbear) built **without
  ECDSA**. If you log in with a FIDO security key such as a YubiKey, its
  `sk-ecdsa` key is refused by the router, even after you add it to
  `authorized_keys` or the admin panel.
- This feed installs a current Dropbear (2026.94), built the way OpenWrt
  builds it, with ECDSA and security-key support switched on.
- It swaps **only the SSH server program**. If the new server does not come up,
  the original is put back automatically, and removing the package restores it
  too. The firmware's SSH settings are not touched.
- The feed is signed, and the installer only trusts the key with fingerprint
  `4fbc7fcb4ae88dd6`.

## Do you need it?

Ask your router which key types it accepts. This runs only the connection
handshake, so it does not log in or ask for a password:

```sh
ssh -vvv -o BatchMode=yes -o PreferredAuthentications=none root@192.168.8.1 exit 2>&1 | grep server-sig-algs
```

A GL-E5800 on firmware 4.10.4 (Dropbear 2024.86) answers

```
server-sig-algs=<ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-256,ssh-rsa>
```

If the list has no `sk-ecdsa-sha2-nistp256@openssh.com` and you want to use an
ECDSA security key (or any `ecdsa-sha2-*` key), you need this feed. With it
installed the router also offers `ecdsa-sha2-nistp256` and
`sk-ecdsa-sha2-nistp256@openssh.com`. Upstream Dropbear has also had eight
releases since 2024.86, several with security fixes.

## Install

On the router, as root:

```sh
curl -fsSL https://digitalcybersoft.github.io/glinet-dropbear-feed/setup.sh -o /tmp/setup.sh
sh /tmp/setup.sh --dry-run
sh /tmp/setup.sh
```

The installer picks the router's architecture, downloads `feed.pub`, refuses
it unless its fingerprint is **`4fbc7fcb4ae88dd6`**, installs it as
`/etc/opkg/keys/4fbc7fcb4ae88dd6`, adds the feed, runs a plain `opkg update`
(the feed's `Packages.sig` must verify) and installs `glinet-dropbear`.
`--dry-run` shows all of that and changes nothing.

```sh
glinet-dropbear status    # active / packaged / saved firmware versions
glinet-dropbear revert    # back to the firmware's Dropbear
glinet-dropbear apply     # forward again
opkg remove glinet-dropbear   # uninstall; restores the firmware's Dropbear
```

## Using a security key afterwards

1. On your computer, create the key on the security key:
   `ssh-keygen -t ecdsa-sk` (or `-t ed25519-sk` if your security key supports
   Ed25519; GL's own Dropbear also advertises that type).
2. Add the `.pub` line to the router: in the admin panel with
   [glinet-sshkeymanagement](https://github.com/DigitalCyberSoft/glinet-sshkeymanagement)
   (System → SSH Keys), or by appending it to `/etc/dropbear/authorized_keys`.
3. `ssh root@192.168.8.1` and touch the key when it blinks.

Keep password login enabled until a key login has worked.

## What to expect

**Can this lock me out?** The package installs the new binary next to the old
one and switches only after checking that the new one runs on your CPU. It
then restarts the SSH service and keeps the new binary only if a server running
it is listening; otherwise it puts the firmware's binary back and restarts
again. Your login methods stay as they were: if password login works today, it
still works.

**Will my SSH client warn about a changed host key?** No. The new server reads
the same host keys from `/etc/dropbear` that the firmware's Dropbear created.

**What happens on a firmware upgrade?** The upgrade replaces the system files,
so the router goes back to GL's Dropbear and forgets this package. Run the
installer again afterwards.

**How do updates arrive?** CI checks every day for a new upstream Dropbear
release, then builds, tests, signs and publishes it. On the router:
`opkg update` (plain, without `--force-signature`), then
`opkg upgrade glinet-dropbear`.

**What about my other feeds?** Unlike the other glinet-* feeds this one is
signed, so never use `--force-signature` with it: that switches the check off.
A plain `opkg update` drops the package lists of any unsigned feeds you also
use until their next forced update. Installed packages are not affected.

**Why not replace GL's `dropbear` package?** Keeping it installed keeps GL's
init script and `/etc/config/dropbear` as they are, avoids a package conflict,
and makes undo a plain file restore.

**What am I trusting?** The upstream Dropbear source (GPG-verified against the
pinned release key), OpenWrt's patches, the zig toolchain (sha256-pinned),
GitHub Actions, and whoever controls this repository. The signing key is a
secret of this repository's `github-pages` environment, so the repository owner
can publish signed builds. The pinned fingerprint stops someone swapping in a
different key; it does not protect against a compromised GitHub account.

## What it builds

| | |
|---|---|
| Source | the upstream release tarball, GPG-verified against the pinned release key (`F7347EF2EE2E07A267628CA944931494F29C6773`, the same fingerprint on the release site and keyserver.ubuntu.com); the pinned version's sha256 also matches OpenWrt's `PKG_HASH` |
| Patches | OpenWrt's full Dropbear patch set, unmodified ([patches/openwrt/SOURCE](patches/openwrt/SOURCE)); `100-pubkey_path.patch` keeps root's keys in `/etc/dropbear/authorized_keys` |
| Options | exactly what OpenWrt's package generates by default ([config/localoptions.h](config/localoptions.h)): ECDSA, Ed25519, FIDO/sk keys, curve25519 + sntrup761 key exchange; no X11, DSS, SHA-1 or CBC |
| Toolchain | `zig cc` with its bundled musl, fully **static**, so one binary per CPU family runs on every GL firmware line regardless of its libc |
| Targets | aarch64 → `aarch64_cortex-a53`; ARM soft-float, ARMv6 baseline without FPU (runs on any ARMv7 core) → `arm_cortex-a7`, `arm_cortex-a7_neon-vfpv4`, `arm_cortex-a9_vfpv3-d16`, `arm_cortex-a15_neon-vfpv4`; MIPS32r2 soft-float → `mips_24kc`; MIPSel → `mipsel_24kc` |

The package, `glinet-dropbear`, installs the binary as
`/usr/lib/glinet-dropbear/dropbear`. Its postinst runs `glinet-dropbear apply`,
which:

1. checks the new binary runs on this CPU,
2. saves the firmware's `/usr/sbin/dropbear` once (as `dropbear.firmware`),
3. renames the new binary into place and restarts the SSH service,
4. waits until a dropbear running the new file is listening, and otherwise
   **puts the firmware binary back** and restarts again.

`dbclient`, `dropbearkey` and `scp` are symlinks to the same binary, so they
switch too.

## How it is built and published

[.github/workflows/build-feed.yml](.github/workflows/build-feed.yml):

1. **resolve**: build the newer of the pinned version and the newest upstream
   release; on the daily schedule skip if that version is already live.
2. **build** (aarch64, arm, mips, mipsel), each:
   - `tools/fetch-source.sh`: download, GPG-verify (and sha256 for the pin)
   - `tools/build.sh`: patches, options, `autoreconf`, static zig build
   - `tools/check-binary.sh`: machine, endianness, static, ARMv6 or later
     with no VFP/NEON on ARM, soft-float on MIPS, required algorithms and
     `/etc/dropbear` compiled in
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
see it. Without the secret the publish job stops before anything is deployed.

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

- `2026.94-1` is published for all seven architecture directories
  (2026-11-27).
- Every build passes the binary checks and the qemu login test.
- The published signatures verify with a GL-E5800's own `usign`, and the
  installer's `--dry-run` works there.
- Not yet installed on real hardware, and not yet tested with a physical
  security key: the smoke test proves ECDSA logins and that the sk key types
  are advertised, not a hardware-key login.
