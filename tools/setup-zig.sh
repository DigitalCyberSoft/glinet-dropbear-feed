#!/bin/sh
# Install the pinned zig toolchain (build.conf ZIG_VERSION/ZIG_SHA256) and print
# the directory holding the zig executable, for adding to PATH.
#
# Usage: tools/setup-zig.sh [DESTDIR]     (default: .zig in the repo)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/build.conf"

DEST=${1:-"$HERE/.zig"}
D="zig-x86_64-linux-$ZIG_VERSION"

if [ ! -x "$DEST/$D/zig" ]; then
	mkdir -p "$DEST"
	curl -fsSL --retry 3 -o "$DEST/$D.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/$D.tar.xz"
	if ! echo "$ZIG_SHA256  $DEST/$D.tar.xz" | sha256sum -c - >/dev/null 2>&1; then
		echo "setup-zig: sha256 mismatch for $D.tar.xz" >&2
		exit 1
	fi
	tar -xJf "$DEST/$D.tar.xz" -C "$DEST"
	rm -f "$DEST/$D.tar.xz"
fi

echo "$DEST/$D"
