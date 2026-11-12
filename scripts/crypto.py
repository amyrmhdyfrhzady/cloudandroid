#!/usr/bin/env python3
"""Streaming AES-256-GCM encryption for large Cloud Android snapshots."""
import argparse
import os
import sys
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

MAGIC = b"CA17GCM1"
CHUNK = 4 * 1024 * 1024


def key_from_env() -> bytes:
    raw = os.environ.get("STATE_ENCRYPTION_KEY", "")
    if len(raw) != 64:
        raise SystemExit("STATE_ENCRYPTION_KEY must be 64 hex characters")
    try:
        key = bytes.fromhex(raw)
    except ValueError as exc:
        raise SystemExit("STATE_ENCRYPTION_KEY is not valid hex") from exc
    if len(key) != 32:
        raise SystemExit("STATE_ENCRYPTION_KEY must decode to 32 bytes")
    return key


def encrypt(src: Path, dst: Path) -> None:
    nonce = os.urandom(12)
    encryptor = Cipher(algorithms.AES(key_from_env()), modes.GCM(nonce)).encryptor()
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    try:
        with src.open("rb") as fin, tmp.open("wb") as fout:
            fout.write(MAGIC + nonce)
            while True:
                block = fin.read(CHUNK)
                if not block:
                    break
                fout.write(encryptor.update(block))
            fout.write(encryptor.finalize())
            fout.write(encryptor.tag)
            fout.flush()
            os.fsync(fout.fileno())
        tmp.replace(dst)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def decrypt(src: Path, dst: Path) -> None:
    size = src.stat().st_size
    if size < len(MAGIC) + 12 + 16:
        raise SystemExit("Encrypted snapshot is truncated")
    tmp = dst.with_suffix(dst.suffix + ".verified.tmp")
    try:
        with src.open("rb") as fin:
            header = fin.read(len(MAGIC) + 12)
            if header[:len(MAGIC)] != MAGIC:
                raise SystemExit("Unknown snapshot format")
            nonce = header[len(MAGIC):]
            fin.seek(-16, os.SEEK_END)
            tag = fin.read(16)
            ciphertext_size = size - len(header) - 16
            fin.seek(len(header))
            decryptor = Cipher(algorithms.AES(key_from_env()), modes.GCM(nonce, tag)).decryptor()
            with tmp.open("wb") as fout:
                remaining = ciphertext_size
                while remaining:
                    block = fin.read(min(CHUNK, remaining))
                    if not block:
                        raise SystemExit("Encrypted snapshot ended unexpectedly")
                    remaining -= len(block)
                    fout.write(decryptor.update(block))
                fout.write(decryptor.finalize())  # Authenticates the complete file.
                fout.flush()
                os.fsync(fout.fileno())
        tmp.replace(dst)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("encrypt", "decrypt"))
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    src, dst = Path(args.source), Path(args.destination)
    if args.mode == "encrypt":
        encrypt(src, dst)
    else:
        decrypt(src, dst)
    print(f"{args.mode} OK: {dst}")


if __name__ == "__main__":
    main()
