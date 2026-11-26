#!/bin/sh
# Run the cross-built binary under qemu-user (binfmt) on a CPU model that lacks
# what the binary must not use, and prove end to end that it
#   - reports the expected version,
#   - generates ed25519 and ECDSA host keys,
#   - accepts ed25519 AND ECDSA public-key logins from OpenSSH,
#   - advertises the FIDO/sk key types in server-sig-algs.
# Publishing is gated on this passing for every architecture.
#
# Usage: tools/smoke-test.sh ARCH BINARY VERSION
set -eu
ARCH=$1
BIN=$(realpath "$2")
V=$3

case "$ARCH" in
	aarch64) QEMU_CPU=cortex-a53 ;;
	arm)     QEMU_CPU=cortex-a9 ;;  # no hardware divide: rejects Cortex-A7/A15-only code
	mips|mipsel) QEMU_CPU=24Kc ;;   # no FPU: rejects hard-float code
	*) echo "smoke-test: unknown arch '$ARCH'" >&2; exit 2 ;;
esac
export QEMU_CPU

# Dropbear refuses authorized_keys whose path is group/world-writable up to the
# home directory or, outside it, up to / (so /tmp fails): stay inside $HOME.
T=$(mktemp -d "$HOME/.dbsmoke.XXXXXX")
PIDF="$T/pid"
cleanup() {
	[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

for n in dropbear dropbearkey dbclient scp; do ln -s "$BIN" "$T/$n"; done

got=$("$T/dropbear" -V 2>&1 | head -n1)
[ "$got" = "Dropbear v$V" ] || { echo "smoke-test($ARCH): version is '$got', expected 'Dropbear v$V'" >&2; exit 1; }

"$T/dropbearkey" -t ed25519 -f "$T/hk_ed25519" >/dev/null
"$T/dropbearkey" -t ecdsa -s 256 -f "$T/hk_ecdsa" >/dev/null

mkdir -m 700 "$T/ak"
for k in ed25519 ecdsa; do
	ssh-keygen -q -t "$k" -N '' -f "$T/id_$k"
	cat "$T/id_$k.pub" >> "$T/ak/authorized_keys"
done
chmod 600 "$T/ak/authorized_keys"

PORT=$((20000 + $$ % 20000))
"$T/dropbear" -F -E -s -p "127.0.0.1:$PORT" -r "$T/hk_ed25519" -r "$T/hk_ecdsa" \
	-P "$PIDF" -D "$T/ak" 2>"$T/server.log" &

i=0
until ssh-keyscan -p "$PORT" 127.0.0.1 >/dev/null 2>&1; do
	i=$((i + 1))
	if [ "$i" -gt 60 ]; then
		echo "smoke-test($ARCH): server never listened" >&2
		cat "$T/server.log" >&2
		exit 1
	fi
	sleep 1
done

U=$(id -un)
SSH="ssh -p $PORT -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
for k in ed25519 ecdsa; do
	out=$($SSH -i "$T/id_$k" "$U@127.0.0.1" 'echo LOGIN-OK' 2>&1) || true
	if [ "$out" != "LOGIN-OK" ]; then
		echo "smoke-test($ARCH): $k public-key login failed: $out" >&2
		cat "$T/server.log" >&2
		exit 1
	fi
done

algs=$($SSH -vvv -i "$T/id_ed25519" "$U@127.0.0.1" true 2>&1 | sed -n 's/.*server-sig-algs=<\(.*\)>.*/\1/p' | head -n1)
for a in ssh-ed25519 ecdsa-sha2-nistp256 sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com; do
	case ",$algs," in
		*",$a,"*) ;;
		*) echo "smoke-test($ARCH): server-sig-algs lacks $a: <$algs>" >&2; exit 1 ;;
	esac
done

echo "smoke-test($ARCH, QEMU_CPU=$QEMU_CPU): Dropbear v$V; ed25519 + ecdsa logins OK; server-sig-algs=<$algs>"
