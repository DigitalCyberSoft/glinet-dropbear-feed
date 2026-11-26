#!/bin/sh
# Decide what to build and whether to publish.
#   version: the newest upstream Dropbear release, never older than build.conf's
#            pin (a newer release is still GPG-verified by fetch-source.sh and
#            must pass every check before it can publish)
#   release: build.conf PKG_RELEASE for the pinned version, 1 for a newer one
#   publish: false only for a scheduled run whose version is already live
# Prints KEY=value lines (for $GITHUB_OUTPUT).
#
# Usage: tools/resolve-version.sh EVENT [FORCE]
#   EVENT  the GitHub event name (schedule, push, workflow_dispatch)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/build.conf"

EVENT=${1:-workflow_dispatch}
FORCE=${2:-false}
FEED=https://digitalcybersoft.github.io/glinet-dropbear-feed

vsort() { sort -t. -k1,1n -k2,2n; }

latest=$(curl -fsSL --retry 3 "$DROPBEAR_URL/" \
	| grep -oE 'dropbear-[0-9]{4}\.[0-9]+\.tar\.bz2' \
	| sed 's/^dropbear-//; s/\.tar\.bz2$//' | vsort | tail -n 1)
if [ -z "$latest" ]; then
	echo "resolve-version: could not read the upstream release list" >&2
	exit 1
fi

version=$(printf '%s\n%s\n' "$DROPBEAR_VERSION" "$latest" | vsort | tail -n 1)
if [ "$version" = "$DROPBEAR_VERSION" ]; then
	release=$PKG_RELEASE
else
	release=1
fi

# A 404 before the first publish leaves "live" empty.
live=$(curl -fsSL "$FEED/aarch64_cortex-a53/Packages" 2>/dev/null | sed -n 's/^Version: //p' | head -n 1)

publish=true
if [ "$EVENT" = schedule ] && [ "$FORCE" != true ] && [ "$live" = "$version-$release" ]; then
	publish=false
fi

echo "version=$version"
echo "release=$release"
echo "live=${live:-none}"
echo "publish=$publish"
