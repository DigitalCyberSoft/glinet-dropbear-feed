#!/bin/sh
# Turn the per-CPU binaries into the signed opkg feed site:
#   SITE/<opkg arch>/glinet-dropbear_<version>_<opkg arch>.ipk
#   SITE/<opkg arch>/Packages, Packages.gz, Packages.sig   (usign-signed)
#   SITE/feed.pub, SITE/setup.sh, SITE/index.html
# Every Packages.sig is verified against keys/feed.pub before this succeeds.
#
# Needs USIGN_SECRET_KEY (contents of the usign secret key file).
#
# Usage: tools/assemble_site.sh BINDIR SITE VERSION RELEASE
#   BINDIR/<cpu>/dropbear for cpu in aarch64 arm mips mipsel
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)

BIN=$1
SITE=$2
V=$3
REL=$4
PV="$V-$REL"

# opkg architecture directory -> CPU build. A static binary runs on every
# variant of its CPU family, so the four builds cover the seven directories
# GL devices use (the same set glinet-tailscale-feed serves).
MAP="aarch64_cortex-a53:aarch64
arm_cortex-a7:arm
arm_cortex-a7_neon-vfpv4:arm
arm_cortex-a9_vfpv3-d16:arm
arm_cortex-a15_neon-vfpv4:arm
mips_24kc:mips
mipsel_24kc:mipsel"

if [ -z "${USIGN_SECRET_KEY:-}" ]; then
	echo "assemble_site: USIGN_SECRET_KEY is not set" >&2
	exit 1
fi

FP=$(python3 "$HERE/tools/usign.py" -F -p "$HERE/keys/feed.pub")
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
rm -rf "$SITE"
mkdir -p "$SITE"

for m in $MAP; do
	A=${m%%:*}
	CPU=${m#*:}
	[ -f "$BIN/$CPU/dropbear" ] || { echo "assemble_site: missing $BIN/$CPU/dropbear" >&2; exit 1; }
	S="$W/stage-$A"
	install -D -m 755 "$BIN/$CPU/dropbear" "$S/usr/lib/glinet-dropbear/dropbear"
	install -D -m 755 "$HERE/pkg/glinet-dropbear" "$S/usr/sbin/glinet-dropbear"
	mkdir -p "$SITE/$A"
	python3 "$HERE/tools/mkipk.py" --name glinet-dropbear --version "$PV" --arch "$A" \
		--section net --depends dropbear \
		--desc "Dropbear SSH $V with OpenWrt's patches and options (ECDSA and FIDO/sk keys), static build for GL.iNet routers. Runs in place of the firmware's Dropbear with automatic rollback; opkg remove restores it." \
		--data-dir "$S" --postinst "$HERE/pkg/postinst" --prerm "$HERE/pkg/prerm" \
		--out "$SITE/$A/glinet-dropbear_${PV}_$A.ipk"
done

for d in "$SITE"/*/; do
	d=${d%/}
	python3 "$HERE/tools/mkindex.py" "$d"
	python3 "$HERE/tools/usign.py" -S -m "$d/Packages" -s - -x "$d/Packages.sig"
	python3 "$HERE/tools/usign.py" -V -m "$d/Packages" -p "$HERE/keys/feed.pub" -x "$d/Packages.sig" >/dev/null
done

cp "$HERE/keys/feed.pub" "$SITE/feed.pub"
sed "s/@FINGERPRINT@/$FP/g" "$HERE/site/setup.sh" > "$SITE/setup.sh"
sed "s/@FINGERPRINT@/$FP/g; s/@VERSION@/$PV/g" "$HERE/site/index.html" > "$SITE/index.html"
touch "$SITE/.nojekyll"

echo "assemble_site: glinet-dropbear $PV, $(echo "$MAP" | wc -l) architectures, Packages signed by $FP"
