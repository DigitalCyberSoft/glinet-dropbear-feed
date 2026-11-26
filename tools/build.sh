#!/bin/sh
# Cross-compile a static Dropbear multi-call binary (dropbear, dbclient,
# dropbearkey, scp) for one architecture with zig cc and its bundled musl,
# applying OpenWrt's patches and build options exactly as OpenWrt does.
#
# Static linking makes one binary per CPU family run on every GL firmware
# line, whatever musl version that firmware ships.
#
# Usage: tools/build.sh ARCH VERSION SRCDIR OUTDIR
#   ARCH    aarch64 | arm | mips | mipsel
#   SRCDIR  holds the verified dropbear-VERSION.tar.bz2 (tools/fetch-source.sh)
#   OUTDIR  receives OUTDIR/dropbear
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)

ARCH=$1
V=$2
SRC=$3
OUT=$4

# ZT: zig target. HOST: autoconf --host triplet. CPU: zig -mcpu.
#   arm:  ARMv6KZ without an FPU (arm1176jz-s). It runs on every ARMv7 core
#         (A7/A9/A15) whether or not it has VFP, NEON or hardware divide.
#         musleabi only sets the soft-float calling convention: with
#         -mcpu=cortex_a9 zig still emitted VFPv3 code (Tag_FP_arch: VFPv3).
#   mips: MIPS32r2 soft float, as OpenWrt's 24Kc targets (no FPU).
case "$ARCH" in
	aarch64) ZT=aarch64-linux-musl;    HOST=aarch64-linux-musl;  CPU=generic ;;
	arm)     ZT=arm-linux-musleabi;    HOST=arm-linux-musleabi;  CPU=arm1176jz_s ;;
	mips)    ZT=mips-linux-musleabi;   HOST=mips-linux-musl;     CPU=mips32r2 ;;
	mipsel)  ZT=mipsel-linux-musleabi; HOST=mipsel-linux-musl;   CPU=mips32r2 ;;
	*) echo "build: unknown arch '$ARCH'" >&2; exit 2 ;;
esac

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
tar -xjf "$SRC/dropbear-$V.tar.bz2" -C "$W"
B="$W/dropbear-$V"

for p in "$HERE"/patches/openwrt/*.patch; do
	patch -d "$B" -p1 --forward --quiet < "$p"
done
cp "$HERE/config/localoptions.h" "$B/localoptions.h"

# OpenWrt "!!DROPBEAR_CLI_MULTIHOP": replace the define in src/sysoptions.h
sed -i 's/^#define DROPBEAR_CLI_MULTIHOP .*/#define DROPBEAR_CLI_MULTIHOP 1/' "$B/src/sysoptions.h"
grep -q '^#define DROPBEAR_CLI_MULTIHOP 1$' "$B/src/sysoptions.h" || {
	echo "build: DROPBEAR_CLI_MULTIHOP replacement did not apply" >&2; exit 1; }

# 900/901 patch configure.ac, so regenerate configure (OpenWrt: PKG_FIXUP:=autoreconf)
(cd "$B" && autoreconf -fi)

# Wrappers: autoconf copes better with a single-word CC than "zig cc -target ...".
mkdir -p "$W/bin"
printf '#!/bin/sh\nexec zig cc -target %s -mcpu=%s "$@"\n' "$ZT" "$CPU" > "$W/bin/cc"
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$W/bin/ar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$W/bin/ranlib"
chmod +x "$W/bin/cc" "$W/bin/ar" "$W/bin/ranlib"

# configure arguments: OpenWrt's CONFIGURE_ARGS with its defaults, plus --enable-static
(cd "$B" && CC="$W/bin/cc" AR="$W/bin/ar" RANLIB="$W/bin/ranlib" \
	CFLAGS="-Os -DARGTYPE=3 -ffunction-sections -fdata-sections" \
	LDFLAGS="-Wl,--gc-sections -s" \
	./configure --host="$HOST" --enable-static \
		--disable-pam --disable-pututxline --disable-utmpx --disable-wtmpx \
		--disable-lastlog --disable-loginfunc --disable-pututline \
		--disable-utmp --disable-wtmp --disable-zlib --enable-bundled-libtom)

make -C "$B" -j"$(nproc)" PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 SCPPROGRESS=1

mkdir -p "$OUT"
cp "$B/dropbearmulti" "$OUT/dropbear"
echo "build: $OUT/dropbear ($(wc -c < "$OUT/dropbear") bytes, $ZT -mcpu=$CPU)"
