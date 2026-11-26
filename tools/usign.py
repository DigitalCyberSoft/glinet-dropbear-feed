#!/usr/bin/env python3
"""usign-compatible key generation and signing, for signing opkg feed indexes.

GL's opkg (option check_signature) verifies every feed's Packages with usign:
Packages.sig must be an Ed25519 signature of Packages by a key whose public
half is installed as /etc/opkg/keys/<fingerprint>. This reproduces OpenWrt
usign's file formats (usign main.c: struct pubkey / seckey / sig, base64 under
an "untrusted comment:" line; fingerprint printed big-endian as %016x) using
the cryptography library, so neither CI nor a workstation needs a C build of
usign and libubox. Signatures are verified against a router's own
/usr/bin/usign before release (see README).

  usign.py -G -s SECFILE -p PUBFILE [-c COMMENT]   generate a key pair
  usign.py -F -p PUBFILE                           print the key fingerprint
  usign.py -S -m FILE -s SECFILE [-x SIGFILE]      sign FILE (default FILE.sig)
  usign.py -V -m FILE -p PUBFILE [-x SIGFILE]      verify a signature

SECFILE "-" reads the secret key file's contents from $USIGN_SECRET_KEY.
"""
import argparse
import base64
import hashlib
import os
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PUBKEY_SIZE = 2 + 8 + 32                 # pkalg, fingerprint, pubkey
SECKEY_SIZE = 2 + 2 + 4 + 16 + 8 + 8 + 64  # pkalg, kdfalg, kdfrounds, salt, checksum, fingerprint, seckey
SIG_SIZE = 2 + 8 + 64                    # pkalg, fingerprint, sig


def write_b64(path, comment, blob, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(f"untrusted comment: {comment}\n{base64.b64encode(blob).decode()}\n")


def parse_b64(text, size, what):
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if len(lines) < 2 or not lines[0].startswith("untrusted comment:"):
        sys.exit(f"usign.py: malformed {what}")
    blob = base64.b64decode(lines[1])
    if len(blob) != size or blob[:2] != b"Ed":
        sys.exit(f"usign.py: {what} is not an Ed25519 usign blob of {size} bytes")
    return blob


def read_text(path, env_fallback=False):
    if path == "-" and env_fallback:
        text = os.environ.get("USIGN_SECRET_KEY", "")
        if not text:
            sys.exit("usign.py: USIGN_SECRET_KEY is empty")
        return text
    with open(path) as f:
        return f.read()


def generate(seckey_path, pubkey_path, comment):
    seed = bytearray(os.urandom(32))
    # usign generate() runs ed25519_prepare() on the seed (scalar clamping)
    seed[0] &= 248
    seed[31] &= 127
    seed[31] |= 64
    pub = Ed25519PrivateKey.from_private_bytes(bytes(seed)).public_key().public_bytes(
        Encoding.Raw, PublicFormat.Raw)
    fp = os.urandom(8)
    sk64 = bytes(seed) + pub
    checksum = hashlib.sha512(sk64).digest()[:8]
    sec = b"Ed" + b"BK" + bytes(4) + os.urandom(16) + checksum + fp + sk64
    write_b64(seckey_path, comment or f"private key {fp.hex()}", sec, 0o600)
    write_b64(pubkey_path, comment or f"public key {fp.hex()}", b"Ed" + fp + pub, 0o644)
    print(fp.hex())


def load_secret(text):
    sec = parse_b64(text, SECKEY_SIZE, "secret key")
    checksum, fp, sk64 = sec[24:32], sec[32:40], sec[40:104]
    if hashlib.sha512(sk64).digest()[:8] != checksum:
        sys.exit("usign.py: secret key checksum mismatch")
    priv = Ed25519PrivateKey.from_private_bytes(sk64[:32])
    if priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw) != sk64[32:]:
        sys.exit("usign.py: secret key halves do not match")
    return priv, fp


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("-G", action="store_true", help="generate a key pair")
    mode.add_argument("-F", action="store_true", help="print fingerprint")
    mode.add_argument("-S", action="store_true", help="sign")
    mode.add_argument("-V", action="store_true", help="verify")
    ap.add_argument("-s", dest="seckey")
    ap.add_argument("-p", dest="pubkey")
    ap.add_argument("-m", dest="message")
    ap.add_argument("-x", dest="sigfile")
    ap.add_argument("-c", dest="comment")
    a = ap.parse_args()

    if a.G:
        if not (a.seckey and a.pubkey):
            ap.error("-G needs -s and -p")
        generate(a.seckey, a.pubkey, a.comment)
    elif a.F:
        if not a.pubkey:
            ap.error("-F needs -p")
        print(parse_b64(read_text(a.pubkey), PUBKEY_SIZE, "public key")[2:10].hex())
    elif a.S:
        if not (a.message and a.seckey):
            ap.error("-S needs -m and -s")
        priv, fp = load_secret(read_text(a.seckey, env_fallback=True))
        with open(a.message, "rb") as f:
            sig = priv.sign(f.read())
        write_b64(a.sigfile or a.message + ".sig", a.comment or f"signed by key {fp.hex()}",
                  b"Ed" + fp + sig, 0o644)
    else:
        if not (a.message and a.pubkey):
            ap.error("-V needs -m and -p")
        pub = parse_b64(read_text(a.pubkey), PUBKEY_SIZE, "public key")
        sig = parse_b64(read_text(a.sigfile or a.message + ".sig"), SIG_SIZE, "signature")
        if sig[2:10] != pub[2:10]:
            sys.exit(f"usign.py: signed by key {sig[2:10].hex()}, not {pub[2:10].hex()}")
        with open(a.message, "rb") as f:
            msg = f.read()
        try:
            Ed25519PublicKey.from_public_bytes(pub[10:]).verify(sig[10:], msg)
        except InvalidSignature:
            sys.exit("usign.py: signature verification FAILED")
        print("OK")


if __name__ == "__main__":
    main()
