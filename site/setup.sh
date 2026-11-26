#!/bin/sh
# glinet-dropbear-feed installer: trust this feed's signing key, add the feed,
# and install glinet-dropbear (Dropbear with ECDSA and FIDO/sk keys).
#
# Usage (on the router, as root):
#   curl -fsSL https://digitalcybersoft.github.io/glinet-dropbear-feed/setup.sh -o /tmp/setup.sh
#   sh /tmp/setup.sh --dry-run    # show what would happen, change nothing
#   sh /tmp/setup.sh              # install
#
# The feed is SIGNED. Its key is installed as /etc/opkg/keys/<fingerprint> and
# opkg verifies Packages.sig on every update, so --force-signature is never
# used. The key downloaded below must have the fingerprint pinned here.
set -eu

BASE="https://digitalcybersoft.github.io/glinet-dropbear-feed"
FEED="gldropbear"
KEY_FP="@FINGERPRINT@"
CUSTOMFEEDS="/etc/opkg/customfeeds.conf"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

DRY=0
case "${1:-}" in
	--dry-run|-n) DRY=1 ;;
	"") ;;
	*) die "unknown argument: $1" ;;
esac

command -v opkg >/dev/null 2>&1 || die "opkg not found: not an OpenWrt/GL.iNet device"
command -v usign >/dev/null 2>&1 || die "usign not found: it is needed to verify the feed"
command -v curl >/dev/null 2>&1 || die "curl not found"
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root"
opkg list-installed | grep -q '^dropbear ' || die "the firmware's dropbear package is not installed"

# highest-priority device architecture that this feed serves
ARCH=""
for a in $(opkg print-architecture | awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3":"$2}' \
		| sort -t: -k1,1 -rn | cut -d: -f2); do
	if curl -fsIL "$BASE/$a/Packages" >/dev/null 2>&1; then
		ARCH=$a
		break
	fi
done
[ -n "$ARCH" ] || die "no build for this device: $(opkg print-architecture | tr '\n' ' ')"

KEYTMP=$(mktemp)
trap 'rm -f "$KEYTMP"' EXIT
curl -fsSL "$BASE/feed.pub" -o "$KEYTMP" || die "cannot download $BASE/feed.pub"
FP=$(usign -F -p "$KEYTMP") || die "downloaded feed.pub is not a usign key"
[ "$FP" = "$KEY_FP" ] || die "feed key fingerprint is $FP, expected $KEY_FP: refusing"

log "device arch: $ARCH"
log "feed:        src/gz $FEED $BASE/$ARCH"
log "signing key: $KEY_FP (fingerprint verified)"

if [ "$DRY" = 1 ]; then
	log "dry run: would install the key as /etc/opkg/keys/$KEY_FP, add the feed line to"
	log "$CUSTOMFEEDS, run opkg update, then opkg install glinet-dropbear. Nothing changed."
	exit 0
fi

mkdir -p /etc/opkg/keys
cp "$KEYTMP" "/etc/opkg/keys/$KEY_FP"

touch "$CUSTOMFEEDS"
sed -i "/ $FEED /d" "$CUSTOMFEEDS"
echo "src/gz $FEED $BASE/$ARCH" >> "$CUSTOMFEEDS"

# Plain update, no --force-signature: opkg keeps this feed's list only if its
# signature verifies. The exit code also counts failures of OTHER configured
# feeds (unsigned ones fail and lose their list until their own forced
# update), so judge success by this feed's list file instead.
opkg update || log "(opkg update reported errors for some feed; checking this one)"
LISTS_DIR=$(awk '$1=="lists_dir" {print $NF}' /etc/opkg.conf 2>/dev/null) || LISTS_DIR=""
[ -s "${LISTS_DIR:-/var/opkg-lists}/$FEED" ] || die "the $FEED list is missing: download failed or its signature was rejected"

opkg install glinet-dropbear
glinet-dropbear status
log "To undo: opkg remove glinet-dropbear (restores the firmware's Dropbear)."
