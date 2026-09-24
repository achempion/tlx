#!/usr/bin/env python3

import argparse
import io
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

REQUIRED_PROGRAMS = ["ssh", "ssh-keygen", "age"]
SSH_CONNECTION_FAILED = 255
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
    claimed_at integer not null,
    relayed_at integer not null,
    body blob not null,
    unique (sender_id, claimed_at)
);

create table if not exists message_recipients (
    sequence integer not null references messages (sequence),
    seen_participant_id integer not null references seen_participants (id),
    primary key (sequence, seen_participant_id)
);

create table if not exists outbox (
    claimed_at integer primary key,
    chat_id text not null,
    recipient_public_keys text,
    body blob not null,
    sent_at integer,
    error text
);
"""


@dataclass(frozen=True)
class Message:
    sequence: int
    chat_id: str
    recipient_public_keys: list[str]
    sender_public_key: str
    claimed_at: int
    relayed_at: int
    body: bytes


@dataclass(frozen=True)
class PutResult:
    accepted: bool
    rejected_public_keys: list[str]
    error: Optional[str]


@dataclass(frozen=True)
class Relay:
    host: str
    port: int
    key_path: Path

    def get(self, last_seen_sequence):
        output = run(self._ssh_command("get", str(last_seen_sequence)))
        if output is None:
            return None
        stream = io.BytesIO(output)
        blobs = []
        while header := stream.readline():
            sequence, size = map(int, header.split())
            blobs.append((sequence, stream.read(size)))
        return blobs

    def put(self, recipient_public_keys, blob):
        result = subprocess.run(self._ssh_command("put", *recipient_public_keys), input=blob, capture_output=True)
        rejected_public_keys = result.stdout.decode().split() if result.returncode == os.EX_NOUSER else []
        refused = result.returncode not in (0, os.EX_NOUSER, SSH_CONNECTION_FAILED)
        error = (result.stderr.decode(errors="replace").strip() or f"exit {result.returncode}") if refused else None
        return PutResult(accepted=result.returncode == 0, rejected_public_keys=rejected_public_keys, error=error)

    def _ssh_command(self, *relay_command):
        return [
            "ssh",
            "-o", "User=tlx",
            "-o", f"Port={self.port}",
            "-o", f"IdentityFile={self.key_path}",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            self.host,
            *relay_command,
        ]


class Storage:
    def __init__(self, database_path, own_public_key):
        self.own_public_key = own_public_key
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
            inserted = self.connection.execute(
                "insert or ignore into messages values (?, ?, ?, ?, ?, ?)",
                (message.sequence, message.chat_id, sender_id, message.claimed_at, message.relayed_at, message.body))
            if inserted.rowcount == 0:
                return
            self.connection.executemany(
                "insert or ignore into message_recipients values (?, ?)",
                [(message.sequence, recipient_id) for recipient_id in recipient_ids])
            self.connection.executemany(
                "update seen_participants set rejected_by_relay_at = null where public_key = ?",
                [(public_key,) for public_key in message.recipient_public_keys])
            if message.sender_public_key == self.own_public_key:
                self.connection.execute("delete from outbox where claimed_at = ?", (message.claimed_at,))

    def mark_rejected(self, public_keys):
        with self.connection:
            self.connection.executemany(
                "update seen_participants set rejected_by_relay_at = ? where public_key = ?",
                [(int(time.time()), public_key) for public_key in public_keys])

    def recipient_public_keys(self, chat_id):
        rows = self.connection.execute(
            "select public_key from seen_participants where chat_id = ? and rejected_by_relay_at is null",
            (chat_id,))
        return [row[0] for row in rows]

    def unsent_outbox_messages(self):
        return self.connection.execute("select claimed_at, chat_id, recipient_public_keys, cast(body as blob) from outbox "
                                       "where sent_at is null and error is null").fetchall()

    def mark_sent(self, claimed_at):
        with self.connection:
            self.connection.execute("update outbox set sent_at = ? where claimed_at = ?", (int(time.time()), claimed_at))

    def mark_failed(self, claimed_at, error):
        with self.connection:
            self.connection.execute("update outbox set error = ? where claimed_at = ?", (error, claimed_at))


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


def decrypt_and_verify(sequence, blob, key_path, own_public_key):
    relayed_at, _, encrypted = blob.partition(b"\n")
    plaintext = run(["age", "-d", "-i", key_path], encrypted)
    if plaintext is None or SIGNATURE_START not in plaintext:
        print(f"message {sequence}: cannot decrypt or not signed", file=sys.stderr)
        return None

    signature_start = plaintext.rindex(SIGNATURE_START)
    signed_content, signature = plaintext[:signature_start], plaintext[signature_start:]
    first_line, _, body = signed_content.partition(b"\n")
    words = first_line.decode(errors="replace").split()
    if len(words) < 3 or not words[1].isdecimal():
        print(f"message {sequence}: first line must be CHAT CLAIMED_AT RECIPIENT_KEY...", file=sys.stderr)
        return None
    chat_id, claimed_at, recipient_public_keys = words[0], int(words[1]), list(dict.fromkeys(words[2:]))
    if own_public_key not in recipient_public_keys:
        print(f"message {sequence}: our key is not listed", file=sys.stderr)
        return None

    sender_public_key = verify(signed_content, signature, recipient_public_keys)
    if sender_public_key is None:
        print(f"message {sequence}: invalid signature", file=sys.stderr)
        return None

    return Message(sequence=sequence, chat_id=chat_id, recipient_public_keys=recipient_public_keys,
                   sender_public_key=sender_public_key, claimed_at=claimed_at, relayed_at=int(relayed_at), body=body)


def listen(relay, storage):
    last_seen_sequence = storage.last_seen_sequence()
    while True:
        blobs = relay.get(last_seen_sequence)
        if blobs is None:
            time.sleep(2)
            continue

        for sequence, blob in blobs:
            last_seen_sequence = sequence
            message = decrypt_and_verify(sequence, blob, relay.key_path, storage.own_public_key)
            if message is not None:
                storage.save_message(message)


def sign_and_encrypt(chat_id, claimed_at, recipient_public_keys, body, key_path):
    signed_content = f"{chat_id} {claimed_at} {' '.join(recipient_public_keys)}\n".encode() + body
    signature = run(["ssh-keygen", "-Y", "sign", "-f", key_path, "-n", "chat"], signed_content)
    if signature is None:
        return None
    age_arguments = [argument for key in recipient_public_keys for argument in ("-r", f"ssh-ed25519 {key}")]
    return run(["age", *age_arguments], signed_content + signature)


def send_outbox(relay, database_path, own_public_key):
    storage = Storage(database_path, own_public_key)
    while True:
        for claimed_at, chat_id, listed_public_keys, body in storage.unsent_outbox_messages():
            listed_public_keys = listed_public_keys.split() if listed_public_keys else storage.recipient_public_keys(chat_id)
            recipient_public_keys = list(dict.fromkeys([own_public_key, *listed_public_keys]))
            while True:
                blob = sign_and_encrypt(chat_id, claimed_at, recipient_public_keys, body, relay.key_path)
                if blob is None:
                    result = PutResult(accepted=False, rejected_public_keys=[], error="cannot sign or encrypt")
                    break
                result = relay.put(recipient_public_keys, blob)
                if not result.rejected_public_keys:
                    break
                storage.mark_rejected(result.rejected_public_keys)
                recipient_public_keys = [key for key in recipient_public_keys if key not in result.rejected_public_keys]
            if result.accepted:
                storage.mark_sent(claimed_at)
            elif result.error:
                storage.mark_failed(claimed_at, result.error)
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description="Sync messages with a tlx relay.")
    parser.add_argument("--host", required=True, help="relay address, for example 203.0.113.10")
    parser.add_argument("--port", type=int, required=True, help="relay SSH port, for example 2222")
    parser.add_argument("--key-path", type=Path, required=True, help="private key, for example ~/.ssh/tlx_ed25519")
    parser.add_argument("--database-path", type=Path, required=True, help="SQLite database, for example ~/tlx.db")
    args = parser.parse_args()
    relay = Relay(args.host, args.port, args.key_path.expanduser())
    database_path = args.database_path.expanduser()

    missing_programs = [program for program in REQUIRED_PROGRAMS if shutil.which(program) is None]
    if missing_programs:
        sys.exit(f"missing required programs: {', '.join(missing_programs)}")

    own_public_key = run(["ssh-keygen", "-y", "-f", relay.key_path]).split()[1].decode()
    print(f"relay: {relay.host}:{relay.port}")
    print(f"key path: {relay.key_path}")
    threading.Thread(target=send_outbox, args=(relay, database_path, own_public_key), daemon=True).start()
    listen(relay, Storage(database_path, own_public_key))


if __name__ == "__main__":
    main()
