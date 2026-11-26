#!/bin/sh
# Download a Dropbear release and verify it before anything is built from it:
#   - the detached GPG signature must be valid and made by the pinned release
#     key (build.conf DROPBEAR_SIGNING_FPR, keys/dropbear-release-signing.asc);
#   - for the pinned version, the tarball must also match build.conf's sha256
#     (the same hash OpenWrt pins for its dropbear package).
#
# Usage: tools/fetch-source.sh VERSION OUTDIR
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/build.conf"

V=$1
OUT=$2
T="dropbear-$V.tar.bz2"
mkdir -p "$OUT"

curl -fsSL --retry 3 -o "$OUT/$T" "$DROPBEAR_URL/$T"
curl -fsSL --retry 3 -o "$OUT/$T.asc" "$DROPBEAR_URL/$T.asc"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$HERE/keys/dropbear-release-signing.asc"

# gpg exits non-zero on a bad or unknown signature; VALIDSIG names the signer.
if ! STATUS=$(gpg --batch --status-fd 1 --verify "$OUT/$T.asc" "$OUT/$T" 2>/dev/null); then
	echo "fetch-source: signature verification FAILED for $T" >&2
	exit 1
fi
if ! printf '%s\n' "$STATUS" | grep -q "^\[GNUPG:\] VALIDSIG .*$DROPBEAR_SIGNING_FPR"; then
	echo "fetch-source: $T is not signed by $DROPBEAR_SIGNING_FPR" >&2
	exit 1
fi

if [ "$V" = "$DROPBEAR_VERSION" ]; then
	if ! echo "$DROPBEAR_SHA256  $OUT/$T" | sha256sum -c - >/dev/null 2>&1; then
		echo "fetch-source: sha256 of $T does not match build.conf" >&2
		exit 1
	fi
fi

echo "fetch-source: $T verified (signed by $DROPBEAR_SIGNING_FPR)"
