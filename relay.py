#!/usr/bin/env python3

import base64
import fcntl
import hashlib
import os
import sys
import time
from pathlib import Path

RELAY_SCRIPT = Path(__file__).resolve()
INBOXES_DIR = Path.home() / "inboxes"
BLOBS_DIR = INBOXES_DIR / ".blobs"
MAX_BLOB_BYTES = 1_000_000

AUTHORIZED_KEYS = Path("/members").read_text().split()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def save(path, blob):
    temp = path.with_name(f".{path.name}.{os.getpid()}.new")
    with open(temp, "wb") as file:
        file.write(blob)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp, path)
    sync_dir(path.parent)


def store_blob(blob):
    blob_path = BLOBS_DIR / hashlib.sha256(blob).hexdigest()
    save(blob_path, blob)
    return blob_path


def read_sequence(path):
    try:
        return int(path.read_text())
    except FileNotFoundError:
        return 0


def deliver(fingerprint, write_blob):
    inbox_dir = INBOXES_DIR / fingerprint
    inbox_dir.mkdir(exist_ok=True)

    with open(inbox_dir / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sequence = read_sequence(inbox_dir / "LATEST") + 1
        save(inbox_dir / "LATEST", str(sequence).encode())
        blob_path = inbox_dir / str(sequence)
        write_blob(blob_path)
        sync_dir(inbox_dir)

    return blob_path


def put(recipient_keys, member_keys):
    recipient_keys = list(dict.fromkeys(recipient_keys))
    if not recipient_keys:
        sys.exit("list at least one recipient")
    if not set(recipient_keys).issubset(member_keys):
        sys.exit("every recipient must be a member")

    blob = sys.stdin.buffer.read(MAX_BLOB_BYTES + 1)
    if not 0 < len(blob) <= MAX_BLOB_BYTES:
        sys.exit(f"blob must be 1-{MAX_BLOB_BYTES} bytes")

    blob_path = store_blob(blob)
    for recipient_key in recipient_keys:
        deliver(fingerprint(recipient_key), lambda path: os.link(blob_path, path))


def get(reader_fingerprint, last_seen_sequence):
    inbox_dir = INBOXES_DIR / reader_fingerprint
    for _ in range(60):
        if read_sequence(inbox_dir / "LATEST") > last_seen_sequence:
            break
        time.sleep(1)

    for sequence in range(last_seen_sequence + 1, read_sequence(inbox_dir / "LATEST") + 1):
        blob_path = inbox_dir / str(sequence)
        if blob_path.exists():
            blob = blob_path.read_bytes()
            sys.stdout.buffer.write(b"%d %d\n" % (sequence, len(blob)) + blob)


def fingerprint(public_key):
    """A fingerprint is a short, fixed-length name computed from a public key: its SHA-256 hash.

    A public key is long:

        AAAAC3NzaC1lZDI1NTE5AAAAIGb3k2...long base64...

    Its fingerprint is always 43 characters:

        uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
    """
    key_bytes = base64.b64decode(public_key)
    return base64.urlsafe_b64encode(hashlib.sha256(key_bytes).digest()).decode().rstrip("=")


def print_authorized_keys(members):
    for member_fingerprint, public_key in members.items():
        print(f'restrict,command="{RELAY_SCRIPT} {member_fingerprint}" ssh-ed25519 {public_key}')


def main():
    members = {fingerprint(public_key): public_key for public_key in AUTHORIZED_KEYS}
    if sys.argv[1:] == ["authorized-keys"]:
        print_authorized_keys(members)
        return

    caller_fingerprint = sys.argv[1] if len(sys.argv) == 2 else ""
    words = os.environ.get("SSH_ORIGINAL_COMMAND", "").split()
    command = words[0] if words else ""
    command_args = words[1:]

    if caller_fingerprint not in members:
        sys.exit("new phone, who dis?")

    os.umask(0o077)
    BLOBS_DIR.mkdir(parents=True, exist_ok=True)

    if command == "put":
        put(command_args, set(AUTHORIZED_KEYS))
    elif command == "get" and len(command_args) == 1 and command_args[0].isascii() and command_args[0].isdecimal():
        get(caller_fingerprint, int(command_args[0]))
    else:
        sys.exit("usage: put PUBLIC_KEY... | get LAST_SEEN_SEQUENCE")


if __name__ == "__main__":
    main()
