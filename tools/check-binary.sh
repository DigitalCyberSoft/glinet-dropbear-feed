#!/bin/sh
# Static checks on a built binary: right machine and endianness, fully static,
# no floating-point/SIMD dependency where the target CPUs may lack it, and the
# features this feed exists for compiled in.
#
# Usage: tools/check-binary.sh ARCH BINARY
set -eu
ARCH=$1
BIN=$2

fail() { echo "check-binary($ARCH): $*" >&2; exit 1; }

HDR=$(readelf -h "$BIN")
ATTR=$(readelf -A "$BIN" 2>/dev/null || true)

case "$ARCH" in
	aarch64)
		echo "$HDR" | grep -q 'Machine:.*AArch64' || fail "not AArch64" ;;
	arm)
		echo "$HDR" | grep -q 'Machine:.*ARM$' || fail "not 32-bit ARM"
		echo "$ATTR" | grep -qE 'Tag_CPU_arch: (v6KZ|v6K|v7)$' || fail "not ARMv6K or later: $(echo "$ATTR" | grep Tag_CPU_arch)"
		if echo "$ATTR" | grep -qE 'Tag_(FP_arch|Advanced_SIMD_arch|ABI_VFP_args)'; then
			fail "uses VFP/NEON: $(echo "$ATTR" | grep -E 'Tag_(FP_arch|Advanced_SIMD_arch|ABI_VFP_args)' | tr '\n' ' ')"
		fi ;;
	mips|mipsel)
		echo "$HDR" | grep -q 'Machine:.*MIPS' || fail "not MIPS"
		if [ "$ARCH" = mips ]; then want=big; else want=little; fi
		echo "$HDR" | grep -q "Data:.*$want endian" || fail "not $want endian"
		echo "$ATTR" | grep -qi 'FP ABI:.*soft' || fail "not soft-float: $(echo "$ATTR" | grep -i 'FP ABI')" ;;
	*) fail "unknown arch" ;;
esac

readelf -l "$BIN" | grep -q 'INTERP' && fail "dynamically linked (has PT_INTERP)"

# Strings that only exist when the feature is compiled in. /etc/dropbear is the
# root authorized_keys directory from OpenWrt's 100-pubkey_path.patch.
for s in ssh-ed25519 ecdsa-sha2-nistp256 sk-ssh-ed25519@openssh.com \
	 sk-ecdsa-sha2-nistp256@openssh.com /etc/dropbear; do
	strings -n 6 "$BIN" | grep -qxF "$s" || fail "missing '$s'"
done

SIZE=$(wc -c < "$BIN")
[ "$SIZE" -lt 2000000 ] || fail "unexpectedly large: $SIZE bytes"

echo "check-binary($ARCH): ok ($SIZE bytes, static, features present)"
