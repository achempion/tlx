#!/usr/bin/env python3

import argparse
import io
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

REQUIRED_PROGRAMS = ["ssh", "ssh-keygen", "age"]
SIGNATURE_START = b"-----BEGIN SSH SIGNATURE-----"

SCHEMA = """
pragma journal_mode = wal;

create table if not exists seen_participants (
    id integer primary key,
    chat_id text not null,
    public_key text not null,
    rejected_by_relay_at integer,
    unique (chat_id, public_key)
);

create table if not exists messages (
    sequence integer primary key,
    chat_id text not null,
    sender_id integer not null references seen_participants (id),
    relayed_at integer not null,
    body blob not null
);

create table if not exists message_recipients (
    sequence integer not null references messages (sequence),
    seen_participant_id integer not null references seen_participants (id),
    primary key (sequence, seen_participant_id)
);
"""


@dataclass(frozen=True)
class Message:
    sequence: int
    chat_id: str
    recipient_public_keys: list[str]
    sender_public_key: str
    relayed_at: int
    body: bytes


class Storage:
    def __init__(self, database_path):
        self.connection = sqlite3.connect(database_path)
        self.connection.executescript(SCHEMA)

    def last_seen_sequence(self):
        row = self.connection.execute("select max(sequence) from messages").fetchone()
        return row[0] or 0

    def seen_participant_id(self, chat_id, public_key):
        self.connection.execute(
            "insert or ignore into seen_participants (chat_id, public_key) values (?, ?)",
            (chat_id, public_key))
        row = self.connection.execute(
            "select id from seen_participants where chat_id = ? and public_key = ?",
            (chat_id, public_key)).fetchone()
        return row[0]

    def save_message(self, message):
        with self.connection:
            recipient_ids = [self.seen_participant_id(message.chat_id, public_key)
                             for public_key in message.recipient_public_keys]
            sender_id = self.seen_participant_id(message.chat_id, message.sender_public_key)
            self.connection.execute(
                "insert or ignore into messages values (?, ?, ?, ?, ?)",
                (message.sequence, message.chat_id, sender_id, message.relayed_at, message.body))
            self.connection.executemany(
                "insert or ignore into message_recipients values (?, ?)",
                [(message.sequence, recipient_id) for recipient_id in recipient_ids])
            self.connection.executemany(
                "update seen_participants set rejected_by_relay_at = null where public_key = ?",
                [(public_key,) for public_key in message.recipient_public_keys])

    def mark_rejected(self, public_keys):
        with self.connection:
            self.connection.executemany(
                "update seen_participants set rejected_by_relay_at = ? where public_key = ?",
                [(int(time.time()), public_key) for public_key in public_keys])


def run(command, stdin=b""):
    result = subprocess.run(command, input=stdin, capture_output=True)
    if result.returncode != 0:
        print(result.stderr.decode(errors="replace").strip(), file=sys.stderr)
        return None
    return result.stdout


def verify(message, signature, recipient_public_keys):
    with tempfile.TemporaryDirectory() as directory:
        signature_path = Path(directory, "signature")
        signature_path.write_bytes(signature)
        signers_path = Path(directory, "signers")
        signers_path.write_text("".join(f"{key} ssh-ed25519 {key}\n" for key in recipient_public_keys))

        sender_public_key = run(["ssh-keygen", "-Y", "find-principals", "-s", signature_path, "-f", signers_path])
        if sender_public_key is None:
            return None
        sender_public_key = sender_public_key.decode().strip()

        verified = run(["ssh-keygen", "-Y", "verify", "-f", signers_path, "-I", sender_public_key,
                        "-n", "chat", "-s", signature_path], message)
        return sender_public_key if verified is not None else None


def listen(host, port, key_path):
    last_seen_sequence = 0
    while True:
        output = run([
            "ssh",
            "-o", "User=tlx",
            "-o", f"Port={port}",
            "-o", f"IdentityFile={key_path}",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            host,
            "get", str(last_seen_sequence),
        ])
        if output is None:
            time.sleep(2)
            continue

        stream = io.BytesIO(output)
        while header := stream.readline():
            sequence, size = map(int, header.split())
            last_seen_sequence = sequence

            plaintext = run(["age", "-d", "-i", key_path], stream.read(size))
            if plaintext is None or SIGNATURE_START not in plaintext:
                print(f"message {sequence}: cannot decrypt or not signed", file=sys.stderr)
                continue

            signature_start = plaintext.rindex(SIGNATURE_START)
            message, signature = plaintext[:signature_start], plaintext[signature_start:]
            recipients_line, _, body = message.partition(b"\n")
            recipient_public_keys = recipients_line.decode(errors="replace").split()

            sender_public_key = verify(message, signature, recipient_public_keys)
            if sender_public_key is None:
                print(f"message {sequence}: invalid signature", file=sys.stderr)
                continue

            text = body.decode(errors="replace")
            print(f"from {sender_public_key}:", flush=True)
            print("".join(c for c in text if c.isprintable() or c == "\n"), flush=True)


def main():
    parser = argparse.ArgumentParser(description="Sync messages with a tlx relay.")
    parser.add_argument("--host", required=True, help="relay address, for example 203.0.113.10")
    parser.add_argument("--port", type=int, required=True, help="relay SSH port, for example 2222")
    parser.add_argument("--key-path", type=Path, required=True, help="private key, for example ~/.ssh/tlx_ed25519")
    args = parser.parse_args()
    key_path = args.key_path.expanduser()

    missing_programs = [program for program in REQUIRED_PROGRAMS if shutil.which(program) is None]
    if missing_programs:
        sys.exit(f"missing required programs: {', '.join(missing_programs)}")

    print(f"relay: {args.host}:{args.port}")
    print(f"key path: {key_path}")
    listen(args.host, args.port, key_path)


if __name__ == "__main__":
    main()
