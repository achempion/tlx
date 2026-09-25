#!/usr/bin/env python3
"""Real relay/daemon integration tests. Run with Python's standard unittest runner."""

import subprocess
import unittest
from contextlib import contextmanager

from support import LocalTlx, make_key, rows


class MessagingTests(unittest.TestCase):
    @contextmanager
    def stack(self):
        with LocalTlx() as self.tlx:
            self.expected, self.failed = [], {"alice": [], "bobx": []}
            yield self.tlx
            self.verify()

    def queue(self, sender, chat, body, recipients=None):
        keys = None if recipients is None else [self.tlx.public_keys[name] for name in recipients]
        stamp = self.tlx.enqueue(sender, chat, body, keys)
        body = body.encode() if isinstance(body, str) else body
        self.expected.append((chat, self.tlx.public_keys[sender], body, stamp))
        return stamp

    def synced(self, recipients=("alice", "bobx")):
        for name in recipients:
            database = self.tlx.databases[name]
            self.tlx.wait(lambda: rows(database, "select count(*) from messages")[0][0] >= len(self.expected),
                          f"all messages at {name}")
            actual = rows(database, "select m.chat_id, p.public_key, m.body, m.claimed_at from messages m "
                          "join seen_participants p on p.id = m.sender_id order by m.claimed_at")
            self.assertEqual(len(actual), len(self.expected))
            for received, expected in zip(actual, sorted(self.expected, key=lambda row: row[3])):
                assert received == expected, (name, expected[0], expected[3])

    def send(self, sender, chat, body, recipients=None):
        self.queue(sender, chat, body, recipients)
        self.synced()

    def verify(self):
        self.synced()
        for name, database in self.tlx.databases.items():
            expected_failures = sorted(self.failed[name])
            self.tlx.wait(lambda: rows(database, "select claimed_at from outbox order by claimed_at") ==
                          [(stamp,) for stamp in expected_failures], f"{name} outbox acknowledgments")
            for _, sent_at, error in rows(database, "select claimed_at, sent_at, error from outbox"):
                self.assertIsNone(sent_at)
                self.assertTrue(error and error.strip())
            self.assertEqual(rows(database, "pragma integrity_check"), [("ok",)])
            self.assertEqual(rows(database, "select count(*) from message_recipients"), [(2 * len(self.expected),)])
            self.assertNotIn("Traceback", (self.tlx.directory / f"{name}.log").read_text())

    def test_chats_payloads_and_burst(self):
        with self.stack():
            self.send("alice", "@plain", "Hi Bob", ["bobx"])
            self.send("bobx", "@plain", "Hi Alice")
            self.send("alice", "launch@first", "Launch plan", ["bobx"])
            self.send("bobx", "launch@first", "Plan received")
            self.send("bobx", "launch@other", "Separate launch", ["alice"])
            self.send("alice", "launch@other", b"\x00\xff" + bytes(range(256)) * 256)
            self.send("bobx", "launch@first", b"L" * 990_000)
            for index in range(6):
                for sender in ("alice", "bobx"):
                    self.queue(sender, "@plain", f"burst {index} from {sender}")

    def test_connection_retry_and_offline_catchup(self):
        with self.stack() as tlx:
            self.send("alice", "@retry", "First message", ["bobx"])
            tlx.ssh_offline.touch()
            stamp = self.queue("alice", "@retry", "Queued during outage")
            tlx.wait(lambda: tlx.ssh_attempts.exists() and " put " in tlx.ssh_attempts.read_text(),
                     "a send attempt during the SSH outage")
            self.assertEqual(rows(tlx.databases["alice"], "select sent_at, error from outbox where claimed_at=?",
                                  (stamp,)), [(None, None)])
            self.assertEqual(rows(tlx.databases["bobx"], "select count(*) from messages where claimed_at=?",
                                  (stamp,)), [(0,)])
            tlx.ssh_offline.unlink()
            self.synced()

            tlx.stop_daemon("bobx")
            self.queue("alice", "@retry", "Catch up later")
            self.synced(("alice",))
            tlx.start_daemon("bobx")
            self.synced()
            for name in ("alice", "bobx"):
                tlx.stop_daemon(name)
                tlx.start_daemon(name)
            self.send("bobx", "@retry", "Both daemons restarted")

    def test_rejected_sends_and_unauthorized_login(self):
        with self.stack() as tlx:
            self.send("alice", "@rejected", "First message", ["bobx"])
            unknown = tlx.directory / "unknown"
            unknown_public = make_key(unknown)
            self.assertNotEqual(tlx.ssh(unknown, "get", "0").returncode, 0)
            for body, recipients in ((b"X" * 1_000_000, None), (b"Unknown recipient", [unknown_public])):
                stamp = tlx.enqueue("alice", "@rejected", body, recipients)
                self.failed["alice"].append(stamp)

                def failed():
                    state = rows(tlx.databases["alice"], "select sent_at, error from outbox where claimed_at=?", (stamp,))
                    self.assertTrue(state, "rejected message disappeared from outbox")
                    sent_at, error = state[0]
                    self.assertIsNone(sent_at)
                    return error

                tlx.wait(failed, "rejected message to have an outbox error")
            self.send("alice", "@rejected", "Valid after rejected sends")

    def test_bad_blobs_do_not_break_receiving(self):
        with self.stack() as tlx:
            self.send("alice", "@invalid", "First message", ["bobx"])
            alice, bob = tlx.public_keys["alice"], tlx.public_keys["bobx"]
            blobs = [b"not an age message"]
            for stamp, recipients in ((1, [bob]), (10**30, [alice, bob])):
                content = f"@invalid {stamp} {' '.join(recipients)}\ninvalid message".encode()
                signature = subprocess.run(
                    ["ssh-keygen", "-Y", "sign", "-f", str(tlx.keys["alice"]), "-n", "chat"],
                    input=content, capture_output=True, check=True).stdout
                args = [arg for key in recipients for arg in ("-r", "ssh-ed25519 " + key)]
                blobs.append(subprocess.run(["age", *args], input=content + signature,
                                            capture_output=True, check=True).stdout)
            for blob in blobs:
                result = tlx.ssh(tlx.keys["alice"], "put", bob, data=blob)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.send("alice", "@invalid", "Valid after malformed messages")


if __name__ == "__main__":
    unittest.main(verbosity=2)
