#!/usr/bin/env python3
"""Independent UI cases over SQLite, plus one real-relay integration case."""

import base64
import os
import tempfile
import time
import unittest
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import patch

from support import LocalTlx, rows
import tlxd
import tui

# Database-only cases need stable public-key identifiers, not private keys or SSH processes.
ALICE, BOB, CAROL = [base64.b64encode(bytes([value]) * 32).decode() for value in (1, 2, 3)]
PLAIN, TOPIC = "@plain", "launch@topic"


def texts(app, selector="MessageRow"):
    return [widget.query_one(".body").content.plain for widget in app.query(selector)]


async def wait_for(pilot, condition, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition()
        if result:
            await pilot.pause()
            return result
        await pilot.pause(0.05)
    raise TimeoutError(f"waiting for {description}")


async def submit(pilot, text):
    pilot.app.composer.value = text
    await pilot.press("enter")
    await pilot.pause()


class FakeDaemon:
    """Uses the real Storage implementation, including acknowledging the sender's outbox."""

    def __init__(self, path):
        self.storage = tlxd.Storage(path, ALICE)
        self.sequence = 0

    def deliver(self, chat, sender, body, recipients=(ALICE, BOB), claimed_at=None):
        self.sequence += 1
        self.storage.save_message(tlxd.Message(
            sequence=self.sequence, chat_id=chat, recipient_public_keys=list(recipients), sender_public_key=sender,
            claimed_at=time.time_ns() if claimed_at is None else claimed_at, relayed_at=int(time.time()), body=body))


class TuiTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tlx-tui-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.daemon = FakeDaemon(self.directory / "tlxd.db")
        self.addCleanup(self.daemon.storage.connection.close)
        self.store = tui.Store(self.directory / "tui.db", self.directory / "tlxd.db", ALICE)
        self.addCleanup(lambda: self.store.connection.close())

    def seed_chats(self):
        self.daemon.deliver(PLAIN, BOB, b"hi alice")
        self.daemon.deliver(PLAIN, ALICE, b"hi bob")
        self.daemon.deliver(TOPIC, CAROL, b"launch plan", (ALICE, BOB, CAROL))

    @asynccontextmanager
    async def app(self, size=(110, 32)):
        app = tui.TlxApp(self.store)
        async with app.run_test(size=size) as pilot:
            await pilot.pause()
            yield app, pilot

    async def test_send_and_echo(self):
        self.seed_chats()
        self.daemon.deliver(TOPIC, BOB, b"\x00\xff" + bytes(range(256)), (ALICE, BOB, CAROL))
        async with self.app() as (app, pilot):
            self.assertEqual(app.active_id, TOPIC)
            self.assertIn("launch plan", texts(app)[0])
            self.assertIn("file, 258 bytes", texts(app)[1])
            await submit(pilot, "hello there")
            pending = self.store.pending(TOPIC)
            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0].body, b"hello there")
            self.assertTrue(texts(app, "MessageRow.pending")[0].endswith("hello there"))
            self.daemon.deliver(TOPIC, ALICE, pending[0].body, (ALICE, BOB, CAROL), pending[0].claimed_at)
            await wait_for(pilot, lambda: not texts(app, "MessageRow.pending") and len(texts(app)) == 3,
                           "echo replacing the pending message")
            self.assertTrue(texts(app)[-1].endswith("hello there"))
            self.assertEqual(self.store.pending(TOPIC), [])

    async def test_unread_and_navigation(self):
        self.seed_chats()
        async with self.app() as (app, pilot):
            self.daemon.deliver(PLAIN, BOB, b"you there?")
            self.daemon.deliver(PLAIN, ALICE, b"sent from my phone")
            await wait_for(pilot, lambda: app.last_sequence == self.daemon.sequence, "new messages")
            self.assertEqual(next(chat.unread for chat in app.chats if chat.id == PLAIN), 2)
            await pilot.press("alt+1")
            await wait_for(pilot, lambda: app.active_id == PLAIN and self.store.last_read(PLAIN) == self.daemon.sequence,
                           "opening and marking the chat read")
            self.assertTrue(texts(app)[-1].endswith("sent from my phone"))
            await pilot.press("alt+down")
            self.assertEqual(app.active_id, TOPIC)
            await pilot.press("alt+up")
            self.assertEqual(app.active_id, PLAIN)
            await pilot.press("ctrl+k")
            self.assertIsInstance(app.screen, tui.Switcher)
            app.screen.query_one("#query").value = "launch"
            await pilot.pause()
            await pilot.press("enter")
            await wait_for(pilot, lambda: app.active_id == TOPIC and app.focused is app.composer, "switcher selection")

    async def test_alias_completion_and_settings_persist(self):
        self.seed_chats()
        async with self.app() as (app, pilot):
            await pilot.press("alt+1")
            app.composer.value = "/al"
            await pilot.press("tab", "tab")
            self.assertEqual(app.composer.value, f"/alias {tui.fingerprint(BOB)[:8]} ")
            await submit(pilot, app.composer.value + "bob")
            self.assertEqual(self.store.aliases(), {BOB: "bob"})
            self.assertTrue(texts(app)[0].startswith("bob\n"))
            app.composer.value = "hi b"
            await pilot.press("tab")
            self.assertEqual(app.composer.value, "hi bob ")
            await submit(pilot, "/theme")
            self.assertEqual(app.theme, "textual-light")
        self.store.connection.close()
        self.store = tui.Store(self.directory / "tui.db", self.directory / "tlxd.db", ALICE)
        async with self.app() as (app, pilot):
            self.assertEqual(app.theme, "textual-light")
            self.assertEqual(self.store.aliases(), {BOB: "bob"})

    async def test_new_chats_and_guided_topics(self):
        self.store.set_alias(BOB, "bob")
        async with self.app() as (app, pilot):
            await submit(pilot, "/new bob")
            await wait_for(pilot, lambda: app.active_id is not None, "new chat")
            plain = app.active_id
            await submit(pilot, "/topic")
            self.assertIsNotNone(app.prompt)
            await submit(pilot, "standup")
            self.assertIsNotNone(app.prompt)
            await submit(pilot, "bob")
            await wait_for(pilot, lambda: app.active_id.startswith("standup@"), "guided topic")
            first = app.active_id
            await submit(pilot, "/topic standup bob")
            await wait_for(pilot, lambda: app.active_id != first, "separate topic with the same name")
            self.assertEqual(len({plain, first, app.active_id}), 3)
            await submit(pilot, "first message")
            pending = self.store.pending(app.active_id)[0]
            self.assertEqual(rows(self.directory / "tlxd.db", "select recipient_public_keys from outbox"), [(BOB,)])
            self.daemon.deliver(app.active_id, ALICE, pending.body, claimed_at=pending.claimed_at)
            await wait_for(pilot, lambda: app.active_id not in app.drafts and not texts(app, "MessageRow.pending"),
                           "new chat acknowledgment")

    async def test_help_and_contact_details(self):
        self.seed_chats()
        self.store.set_alias(BOB, "bob")
        async with self.app() as (app, pilot):
            await submit(pilot, "/who")
            self.assertIsInstance(app.screen, tui.Sheet)
            detail = app.screen.query_one("#rows").content.plain
            self.assertIn("bob", detail)
            self.assertNotIn(BOB, detail)
            await pilot.press("k")
            self.assertIn(BOB, app.screen.query_one("#rows").content.plain)
            await pilot.press("escape")
            await submit(pilot, "/help")
            self.assertIsInstance(app.screen, tui.Sheet)
            self.assertIn("/new", app.screen.query_one("#rows").content.plain)
            await pilot.press("escape")
            self.assertIs(app.focused, app.composer)

    async def test_composer_and_reading_keys(self):
        self.seed_chats()
        async with self.app() as (app, pilot):
            cases = [
                ("hello world", ("ctrl+w",), "hello "),
                ("hello world", ("alt+b", "alt+d"), "hello "),
                ("hello", ("ctrl+a", "ctrl+k", "ctrl+y"), "hello"),
                ("hello", ("ctrl+u",), ""),
                ("ab", ("ctrl+t",), "ba"),
                ("one", ("ctrl+j", "t", "w", "o"), "one\ntwo"),
            ]
            for text, keys, expected in cases:
                with self.subTest(keys=keys):
                    app.composer.value = text
                    await pilot.press(*keys)
                    self.assertEqual(app.composer.value, expected)
            app.composer.clear()
            await pilot.press("escape", "j", "k", "g", "G")
            self.assertIs(app.focused, app.log_view)
            await pilot.press("x")
            self.assertIs(app.focused, app.composer)
            self.assertEqual(app.composer.value, "x")

    async def test_failed_message_retry_and_discard(self):
        self.seed_chats()
        async with self.app() as (app, pilot):
            await submit(pilot, "cannot send")
            stamp = self.store.pending(TOPIC)[0].claimed_at
            self.daemon.storage.mark_failed(stamp, "relay refused the message")
            await wait_for(pilot, lambda: "relay refused" in "".join(texts(app, "MessageRow.pending")), "visible send error")
            await pilot.press("escape", "r")
            self.assertIsNone(self.store.pending(TOPIC)[0].error)
            self.daemon.storage.mark_failed(stamp, "relay refused again")
            await wait_for(pilot, lambda: "refused again" in "".join(texts(app, "MessageRow.pending")), "second send error")
            await pilot.press("d")
            await wait_for(pilot, lambda: not texts(app, "MessageRow.pending"), "discarded message")
            self.assertEqual(self.store.pending(TOPIC), [])

    async def test_unread_scroll_anchor_and_echo(self):
        now = time.time_ns()
        for index in range(40):
            self.daemon.deliver(TOPIC, BOB if index % 2 else ALICE, f"message {index}".encode(),
                                claimed_at=now - (40 - index) * 60 * 10**9)
        self.store.mark_read(TOPIC, 30)
        async with self.app(size=(100, 24)) as (app, pilot):
            log = app.log_view
            await wait_for(pilot, lambda: len(app.query("NewLine")) == 1 and
                           0 <= app.query_one("NewLine").region.y - log.content_region.y <= 1,
                           "unread boundary scrolled into view")
            self.assertFalse(log.is_vertical_scroll_end)
            await submit(pilot, "long enough to wrap the composer onto a second line " * 3)
            await wait_for(pilot, lambda: not app.query("NewLine") and log.is_vertical_scroll_end, "reply scrolled to bottom")
            height = log.max_scroll_y
            pending = self.store.pending(TOPIC)[0]
            self.daemon.deliver(TOPIC, ALICE, pending.body, claimed_at=pending.claimed_at)
            await wait_for(pilot, lambda: not texts(app, "MessageRow.pending") and app.read_marker == 41, "echo and read marker")
            self.assertEqual(log.max_scroll_y, height, "echo must preserve the layout")
            self.assertTrue(log.content_region.contains_region(app.query("MessageRow").last().region))
            await pilot.press("escape", "g", "escape")
            self.assertFalse(log.is_vertical_scroll_end)
            await submit(pilot, "another")
            await wait_for(pilot, lambda: log.is_vertical_scroll_end, "reply from older history")

    async def test_history_paging(self):
        count = tui.PAGE * 2 + 5
        now = time.time_ns()
        for index in range(count):
            self.daemon.deliver(PLAIN, BOB, f"message {index}".encode(), claimed_at=now + index)
        async with self.app(size=(100, 30)) as (app, pilot):
            self.assertEqual(len(texts(app)), tui.PAGE)
            self.assertTrue(app.log_view.is_vertical_scroll_end)
            await pilot.press("escape", "g")
            await wait_for(pilot, lambda: len(texts(app)) == 2 * tui.PAGE, "older page")
            await pilot.press("g")
            await wait_for(pilot, lambda: len(texts(app)) == count and not app.has_older, "last page")
            self.assertEqual([text.split("\n")[-1] for text in texts(app)], [f"message {index}" for index in range(count)])


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def test_roundtrip_and_client_started_daemon(self):
        with LocalTlx() as tlx:
            alice_db, bob_db = tlx.databases["alice"], tlx.databases["bobx"]
            store = tui.Store(tlx.directory / "tui.db", alice_db, tlx.public_keys["alice"])
            try:
                app = tui.TlxApp(store)
                async with app.run_test(size=(100, 30)) as pilot:
                    await submit(pilot, f"/topic coffee {tlx.public_keys['bobx']}")
                    await wait_for(pilot, lambda: app.active_id is not None, "new topic")
                    chat = app.active_id
                    await submit(pilot, "hello from the TUI")
                    await wait_for(pilot, lambda: rows(bob_db, "select body from messages where chat_id=?", (chat,)), "Bob receiving")
                    self.assertEqual(rows(bob_db, "select body from messages where chat_id=?", (chat,)), [(b"hello from the TUI",)])
                    await wait_for(pilot, lambda: not texts(app, "MessageRow.pending") and len(texts(app)) == 1, "sender echo")
                    tlx.enqueue("bobx", chat, b"hi from Bob")
                    await wait_for(pilot, lambda: len(texts(app)) == 2, "Bob's reply")
                    self.assertTrue(texts(app)[-1].endswith("hi from Bob"))

                    tlx.stop_daemon("bobx")
                    with patch.dict(os.environ, tlx.environment):
                        daemon = tui.start_daemon(tlx.directory / "bobx", "127.0.0.1", tlx.port)
                    try:
                        await submit(pilot, "are you back?")
                        await wait_for(pilot, lambda: rows(bob_db, "select count(*) from messages") == [(3,)], "client-started daemon")
                        await wait_for(pilot, lambda: not store.pending(chat), "last sender acknowledgment")
                        self.assertIsNone(daemon.poll())
                        self.assertTrue((tlx.directory / "bobx" / "tlxd.log").exists())
                    finally:
                        daemon.terminate()
                        daemon.wait(timeout=5)
                    for database in (alice_db, bob_db):
                        self.assertEqual(rows(database, "pragma integrity_check"), [("ok",)])
                        self.assertEqual(rows(database, "select count(*) from outbox"), [(0,)])
            finally:
                store.connection.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
