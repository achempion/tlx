#!/usr/bin/env python3
"""Example UI for tlx: a keyboard-first chat client over the database tlxd keeps in sync."""

import argparse
import base64
import hashlib
import secrets
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass, replace
from datetime import datetime
from functools import partial
from pathlib import Path
from typing import Optional

from textual import on
from textual.app import App
from textual.binding import Binding
from textual.color import Color
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widget import Widget
from textual.fuzzy import Matcher
from textual.content import Content
from textual.message import Message as UIMessage
from textual.screen import ModalScreen
from textual.widgets import Input, OptionList, Static, TextArea
from textual.widgets.option_list import Option

STATE_SCHEMA = """
create table if not exists read (chat_id text primary key, sequence integer not null);
create table if not exists alias (public_key text primary key, name text not null unique);
create table if not exists setting (key text primary key, value text not null);
"""

USAGE = {
    "new": ("/new PERSON…", "start a chat with these people"),
    "topic": ("/topic NAME PERSON…", "start a named chat, shown as #NAME"),
    "alias": ("/alias PERSON NAME", "call a contact by a name"),
    "who": ("/who", "who is in this chat"),
    "theme": ("/theme", "switch between dark and light"),
    "help": ("/help", "commands and keys"),
    "quit": ("/quit", "quit"),
}

# What each argument asks for: the same words serve the prompts and the hint under a half-typed command.
WHO = ("Who?", "a contact's name, or paste a key  ·  Tab lists names")
QUESTIONS = {
    "new": [WHO],
    "topic": [("What is it about?", "a short name, like launch"), WHO],
    "alias": [("Which contact?", "a name, or the code shown next to their messages  ·  Tab lists them"),
              ("What should they be called?", "a short name")],
}

BODY_PREVIEW_LIMIT = 4000


@dataclass(frozen=True)
class Chat:
    id: str
    number: int
    last_sequence: int
    unread: int
    participants: tuple[str, ...]


@dataclass(frozen=True)
class Message:
    sequence: int
    chat_id: str
    sender: str
    claimed_at: int
    body: bytes


@dataclass(frozen=True)
class Pending:
    claimed_at: int
    body: bytes
    sent: bool
    error: Optional[str]


class Store:
    """Everything that touches SQLite.

    The daemon's database is attached as `d`: this reads its tables and writes only to `outbox`,
    which is the documented way to send. Read markers and aliases live in the client's own file.
    """

    def __init__(self, state_path, sync_path, own_public_key):
        self.me = own_public_key
        self.last_claimed_at = 0
        self.connection = sqlite3.connect(state_path, timeout=5)
        self.connection.execute("attach database ? as d", (str(sync_path),))
        self.connection.executescript(STATE_SCHEMA)

    def data_version(self):
        """Changes whenever another connection commits to the daemon's database."""
        return self.connection.execute("pragma d.data_version").fetchone()[0]

    def last_sequence(self):
        return self.connection.execute("select coalesce(max(sequence), 0) from d.messages").fetchone()[0]

    def chats(self):
        """Chats in first-seen order, which never changes under the cursor."""
        participants = {}
        for chat_id, public_key in self.connection.execute(
                "select chat_id, public_key from d.seen_participants "
                "where public_key != ? and rejected_by_relay_at is null order by id", (self.me,)).fetchall():
            participants.setdefault(chat_id, []).append(public_key)
        rows = self.connection.execute(
            "select m.chat_id, max(m.sequence), sum(m.sequence > coalesce(r.sequence, 0) and p.public_key != ?) "
            "from d.messages m join d.seen_participants p on p.id = m.sender_id "
            "left join read r on r.chat_id = m.chat_id "
            "group by m.chat_id order by min(m.sequence)", (self.me,)).fetchall()
        drafts = self.connection.execute(
            "select chat_id from d.outbox where chat_id not in (select chat_id from d.messages) "
            "group by chat_id order by min(claimed_at)").fetchall()
        chats = []
        for chat_id, last_sequence, unread in rows:
            chats.append(Chat(chat_id, len(chats) + 1, last_sequence, unread, tuple(participants.get(chat_id, ()))))
        for (chat_id,) in drafts:
            chats.append(Chat(chat_id, len(chats) + 1, 0, 0, tuple(participants.get(chat_id, ()))))
        return chats

    MESSAGES = ("select m.sequence, m.chat_id, p.public_key, m.claimed_at, m.body "
                "from d.messages m join d.seen_participants p on p.id = m.sender_id ")

    def messages(self, chat_id, limit, before=None):
        """The newest `limit` messages of a chat, or the ones older than `before`, oldest first."""
        rows = self.connection.execute(
            self.MESSAGES + "where m.chat_id = ? and (? is null or m.sequence < ?) order by m.sequence desc limit ?",
            (chat_id, before, before, limit)).fetchall()
        return [Message(*row) for row in reversed(rows)]

    def messages_after(self, sequence):
        rows = self.connection.execute(self.MESSAGES + "where m.sequence > ? order by m.sequence", (sequence,)).fetchall()
        return [Message(*row) for row in rows]

    def pending(self, chat_id):
        rows = self.connection.execute(
            "select claimed_at, cast(body as blob), sent_at is not null, error "
            "from d.outbox where chat_id = ? order by claimed_at", (chat_id,)).fetchall()
        return [Pending(claimed_at, body, bool(sent), error) for claimed_at, body, sent, error in rows]

    def send(self, chat_id, body, recipients=None):
        self.last_claimed_at = claimed_at = max(time.time_ns(), self.last_claimed_at + 1)
        with self.connection:
            self.connection.execute(
                "insert into d.outbox (claimed_at, chat_id, recipient_public_keys, body) values (?, ?, ?, ?)",
                (claimed_at, chat_id, " ".join(recipients) if recipients else None, body))
        return claimed_at

    def retry(self, claimed_at):
        with self.connection:
            self.connection.execute("update d.outbox set error = null where claimed_at = ?", (claimed_at,))

    def discard(self, claimed_at):
        with self.connection:
            self.connection.execute("delete from d.outbox where claimed_at = ?", (claimed_at,))

    def last_read(self, chat_id):
        row = self.connection.execute("select sequence from read where chat_id = ?", (chat_id,)).fetchone()
        return row[0] if row else 0

    def mark_read(self, chat_id, sequence):
        with self.connection:
            self.connection.execute(
                "insert into read (chat_id, sequence) values (?, ?) "
                "on conflict (chat_id) do update set sequence = max(sequence, excluded.sequence)", (chat_id, sequence))

    def aliases(self):
        return dict(self.connection.execute("select public_key, name from alias").fetchall())

    def set_alias(self, public_key, name):
        with self.connection:
            self.connection.execute(
                "insert into alias (public_key, name) values (?, ?) "
                "on conflict (public_key) do update set name = excluded.name", (public_key, name))

    def known_keys(self):
        return [row[0] for row in self.connection.execute("select distinct public_key from d.seen_participants")]

    def setting(self, key, default):
        row = self.connection.execute("select value from setting where key = ?", (key,)).fetchone()
        return row[0] if row else default

    def set_setting(self, key, value):
        with self.connection:
            self.connection.execute("insert into setting (key, value) values (?, ?) "
                                    "on conflict (key) do update set value = excluded.value", (key, value))


HUES = 12   # about as many as a reader can tell apart in a name; more would only look alike


def color_of(public_key, light_theme=False):
    """One of 12 hues spaced around the wheel, always the same for a key, lit for the theme's background."""
    hue = hashlib.sha256(public_key.encode()).digest()[0] % HUES / HUES
    return Color.from_hsl(hue, 0.6, 0.42 if light_theme else 0.68).hex


def fingerprint(public_key):
    """The relay's name for a key, so it can be matched against inbox directories."""
    try:
        key_bytes = base64.b64decode(public_key)
    except ValueError:
        key_bytes = public_key.encode()
    return base64.urlsafe_b64encode(hashlib.sha256(key_bytes).digest()).decode().rstrip("=")


FILE_TYPES = [(b"\x89PNG", ".png"), (b"\xff\xd8", ".jpg"), (b"GIF8", ".gif"), (b"%PDF", ".pdf")]


def file_extension(body):
    return next((extension for magic, extension in FILE_TYPES if body.startswith(magic)), ".bin")


def as_text(body):
    """The body as text, or None when it is a file."""
    try:
        text = body.decode()
    except UnicodeDecodeError:
        return None
    if any(character < " " and character not in "\n\t" for character in text[:BODY_PREVIEW_LIMIT]):
        return None
    return text


def render_body(body):
    """Text as is; a file or an overlong text as a short tag."""
    text = as_text(body)
    if text is None:
        return f"[{file_extension(body)[1:]} file, {len(body):,} bytes]"
    if len(text) > BODY_PREVIEW_LIMIT:
        return text[:BODY_PREVIEW_LIMIT] + f"… [{len(body):,} bytes]"
    return text.rstrip("\n")


def when(claimed_at):
    """The time column: the clock today, the day otherwise."""
    try:
        moment = datetime.fromtimestamp(claimed_at / 1e9)
    except (OverflowError, OSError, ValueError):
        return "?"
    today = datetime.now().date()
    if moment.date() == today:
        return moment.strftime("%H:%M")
    if (today - moment.date()).days == 1:
        return "Yesterday"
    return moment.strftime("%b %d" if moment.year == today.year else "%b %d, %Y")


def chat_tag(chat_id):
    tag, at, ident = chat_id.partition("@")
    return tag if at else ""


def fit(items, width, separator="  ·  "):
    """Join items while they fit in width, dropping the rest."""
    text = ""
    for item in items:
        candidate = f"{text}{separator}{item}" if text else item
        if len(candidate) > width:
            break
        text = candidate
    return text


GROUP_WINDOW_NS = 5 * 60 * 10**9
PAGE = 60
KEY_HINTS = ["^K chats and actions", "Esc read"]
KEYS = [
    ("Ctrl+K", "chats and actions; with text typed, delete to the end of the line"),
    ("Alt+↑ / Alt+↓", "previous / next chat"),
    ("Alt+1 … Alt+9", "the chat with that number in the sidebar"),
    ("Esc", "reading mode: j k g G scroll, r retries and d discards a failed message"),
    ("Ctrl+J", "new line"),
    ("Tab", "complete a command or a name"),
    ("Ctrl+Q", "quit"),
]

# One type system for every list on screen: three tones, bold only for what needs you, accent only for "here".
TONE = {"primary": "$foreground", "muted": "$foreground-muted", "faint": "$foreground 45%", "accent": "$primary"}


# --- widgets: they render what they are given and post messages; policy lives in the app ---


class ChatList(OptionList, can_focus=False):
    """An index of chats, then topics, each under a heading. The highlighted option is the open chat.

    It never takes focus: a click opens a chat and leaves the caret in the composer.
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.chats = []

    def set_chats(self, chats, name_of, active_id):
        def label_of(chat):
            return self.label(chat, name_of(chat), chat.id == active_id)
        if [chat.id for chat in chats] == [chat.id for chat in self.chats]:
            for chat in chats:
                self.replace_option_prompt(chat.id, label_of(chat))
        else:
            options, section = [], None
            for chat in chats:
                heading = "TOPICS" if chat_tag(chat.id) else "CHATS"
                if heading != section:
                    if options:
                        options.append(Option("", disabled=True))
                    options.append(Option(Content.assemble((f" {heading}", TONE["faint"])), disabled=True))
                    section = heading
                options.append(Option(label_of(chat), id=chat.id))
            self.set_options(options)
            if any(chat.id == active_id for chat in chats):
                self.highlighted = self.get_option_index(active_id)
        self.chats = chats

    def label(self, chat, name, active):
        """Muted when read, bold when unread, a bar at the left when open; the count at the right."""
        width = max(self.content_size.width, 20) - 4
        badge = f" {chat.unread}" if chat.unread else ""
        if len(name) > width - len(badge):
            name = name[:width - len(badge) - 1] + "…"
        tone = "bold " + TONE["primary"] if chat.unread else (TONE["primary"] if active else TONE["muted"])
        return Content.assemble(("▌" if active else " ", TONE["accent"]), (f"{chat.number:>2} ", TONE["faint"]),
                                (name, tone), " " * (width - len(name) - len(badge)), (badge, "bold " + TONE["primary"]))

    def highlight(self, chat_id):
        self.highlighted = self.get_option_index(chat_id)


class Gutter(Static):
    """The line between the sidebar and the messages: a stroke at the right edge of its tinted cell, so the
    sidebar's surface ends exactly at the line and the composer's rule meets it."""

    DEFAULT_CSS = "Gutter { width: 1; height: 100%; color: $foreground 15%; }"

    def draw(self, tee_row, tee_style="", highlight_row=None):
        """Rows: the stroke; the composer's row in the composer's color; the open chat's row on its highlight."""
        parts = []
        for row in range(self.size.height):
            style = tee_style if row == tee_row else ("on $foreground 12%" if row == highlight_row else "")
            parts += [("▕", style), "\n"]
        self.update(Content.assemble(*parts[:-1]))


class MessageRow(Widget):
    """A message: its text on the left, the time in a column on the right."""

    DEFAULT_CSS = """
    MessageRow { layout: horizontal; height: auto; }
    MessageRow.group { margin-top: 1; }
    MessageRow > .body { width: 1fr; height: auto; }
    MessageRow > .when { width: 14; height: auto; padding-left: 2; text-align: right; color: $foreground 45%; }
    """

    def __init__(self, body, when, id, group=False, pending=False):
        classes = " ".join(name for name, on in (("group", group), ("pending", pending)) if on)
        super().__init__(id=id, classes=classes)
        self.body = body
        self.when = when

    def compose(self):
        yield Static(self.body, classes="body", markup=False)
        yield Static(self.when, classes="when", markup=False)

    def update_from(self, other):
        self.body, self.when = other.body, other.when
        self.query_one(".body", Static).update(other.body)
        self.query_one(".when", Static).update(other.when)


class NewLine(Static):
    """The line where reading left off."""

    DEFAULT_CSS = "NewLine { height: 1; color: $primary; text-wrap: nowrap; text-overflow: clip; }"

    def __init__(self):
        super().__init__("new " + "─" * 300, markup=False)


class MessageLog(VerticalScroll):
    """The open chat, oldest at the top. Outbox rows show at the bottom until their echo arrives."""

    at_end = True   # whether the reader was at the bottom before the latest change

    def watch_scroll_y(self, old_value, new_value):
        super().watch_scroll_y(old_value, new_value)
        self.at_end = new_value >= self.max_scroll_y

    def on_resize(self, event):
        # the composer growing or shrinking resizes the log: keep the end in view if it was in view
        if self.at_end:
            self.scroll_end(animate=False)

    async def show(self, rows, scroll_to=None):
        """Rebuild anchored, so the first layout is already at the end and nothing jumps, then let go.

        Textual's anchor is only borrowed for that first layout: kept on, it drives the scroll position
        negative when the chat is shorter than the viewport, and every at-the-end check fails.
        """
        await self.remove_children()
        self.anchor()
        await self.mount_all(rows)

        def settle():
            self.anchor(False)
            self.scroll_y = self.max_scroll_y        # validated, which clamps the anchor's negative value
            self.scroll_target_y = self.scroll_y
            self.at_end = True
            if scroll_to is not None:
                self.scroll_to_widget(scroll_to, top=True, animate=False, immediate=True)
        self.call_after_refresh(settle)

    async def prepend(self, rows):
        """Older messages above the current ones, keeping the same row in view."""
        first = self.children[0] if self.children else None
        await self.mount_all(rows, before=first)
        if first is not None:
            self.call_after_refresh(self.scroll_to_widget, first, top=True, animate=False, immediate=True)

    async def append(self, row):
        pinned = self.is_vertical_scroll_end
        await self.mount(row)
        if pinned:
            self.scroll_end(animate=False)

    async def reconcile_pending(self, rows):
        wanted = {row.id: row for row in rows}
        for existing in list(self.query(".pending")):
            if existing.id in wanted:
                existing.update_from(wanted.pop(existing.id))
            else:
                await existing.remove()
        for row in wanted.values():
            await self.append(row)


class Composer(TextArea):
    """The message box: grows with the text, Enter sends, Ctrl+J adds a line, readline keys edit, Tab completes."""

    BINDINGS = [
        Binding("shift+enter,alt+enter,ctrl+j", "newline", show=False),
        Binding("ctrl+b", "cursor_left", show=False),
        Binding("ctrl+f", "cursor_right", show=False),
        Binding("alt+b", "cursor_word_left", show=False),
        Binding("alt+f", "cursor_word_right", show=False),
        Binding("ctrl+k", "kill_or_switch", show=False),
        Binding("ctrl+u", "kill('delete_to_start_of_line')", show=False),
        Binding("ctrl+w,alt+backspace,ctrl+backspace", "kill('delete_word_left')", show=False),
        Binding("alt+d,alt+delete", "kill('delete_word_right')", show=False),
        Binding("ctrl+y", "yank", show=False),
        Binding("ctrl+t", "transpose", show=False),
        Binding("tab", "complete", show=False),
    ]

    class Submitted(UIMessage):
        def __init__(self, value):
            super().__init__()
            self.value = value

    class Reshaped(UIMessage):
        """Size or focus changed: whatever draws around the composer should redraw."""

    def on_resize(self, event):
        self.post_message(self.Reshaped())

    def on_focus(self, event):
        self.post_message(self.Reshaped())

    def on_blur(self, event):
        self.post_message(self.Reshaped())

    class Completions(UIMessage):
        def __init__(self, candidates, index):
            super().__init__()
            self.candidates = candidates
            self.index = index

    def __init__(self, completer, **kwargs):
        super().__init__(soft_wrap=True, tab_behavior="focus", show_line_numbers=False,
                         highlight_cursor_line=False, **kwargs)
        self.completer = completer
        self.killed = ""
        self.cycle = None

    # single-line conveniences over the document
    @property
    def value(self):
        return self.text

    @value.setter
    def value(self, text):
        self.text = text
        last = self.document.line_count - 1
        self.move_cursor((last, len(self.document.get_line(last))))

    @property
    def cursor_position(self):
        return self.cursor_location[1]

    @cursor_position.setter
    def cursor_position(self, column):
        self.move_cursor((self.cursor_location[0], column))

    async def _on_key(self, event):
        """TextArea turns Enter into a newline before bindings run; here Enter sends instead."""
        if event.key == "enter":
            event.stop()
            event.prevent_default()
            self.post_message(self.Submitted(self.text))
            return
        await super()._on_key(event)

    def action_newline(self):
        self.insert("\n")

    def action_kill_or_switch(self):
        if self.text:
            self.action_kill("delete_to_end_of_line")
        else:
            self.app.action_switcher()

    def action_kill(self, action):
        """Run one of TextArea's delete actions and remember what it removed, for yank."""
        before = self.text
        getattr(self, f"action_{action}")()
        after = self.text
        shared = min(len(before), len(after))
        prefix = 0
        while prefix < shared and before[prefix] == after[prefix]:
            prefix += 1
        suffix = 0
        while suffix < shared - prefix and before[-1 - suffix] == after[-1 - suffix]:
            suffix += 1
        removed = before[prefix:len(before) - suffix]
        if removed:
            self.killed = removed

    def action_yank(self):
        if self.killed:
            self.insert(self.killed)

    def action_transpose(self):
        row, column = self.cursor_location
        line = self.document.get_line(row)
        if len(line) < 2:
            return
        if column == len(line):
            column -= 1
        if column == 0:
            return
        self.replace(line[column] + line[column - 1], (row, column - 1), (row, column + 1))
        self.move_cursor((row, column + 1))

    def action_complete(self):
        """Complete the word at the cursor; a unique match also gets a space, repeated Tabs cycle the rest."""
        row, column = self.cursor_location
        line = self.document.get_line(row)
        if self.cycle and self.cycle[0] == (row, line):
            _, candidates, index, start = self.cycle
            end = start + len(candidates[index])
            index = (index + 1) % len(candidates)
        else:
            start = line.rfind(" ", 0, column) + 1
            candidates, index, end = self.completer(line, start, line[start:column]), 0, column
            if not candidates:
                return
        replacement = candidates[index] + (" " if len(candidates) == 1 else "")
        self.replace(replacement, (row, start), (row, end))
        self.move_cursor((row, start + len(replacement)))
        self.cycle = ((row, self.document.get_line(row)), candidates, index, start) if len(candidates) > 1 else None
        self.post_message(self.Completions(candidates, index))


class Sheet(ModalScreen):
    """A small centred panel: a title, aligned rows, a hint line. Esc closes, k reveals keys.

    Rows are (label, detail, key, style) tuples; a row with an empty label is a spacer.
    """

    DEFAULT_CSS = """
    Sheet { align: center middle; background: $background 60%; }
    Sheet > Vertical { width: 64; max-width: 90%; height: auto; padding: 1 2; background: $surface; border: round $panel; }
    Sheet .title { margin-bottom: 1; }
    Sheet .hint { color: $foreground-muted; margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "dismiss", show=False), Binding("k", "toggle_keys", show=False)]

    def __init__(self, title, rows, footnote=""):
        super().__init__()
        self.title_text = title
        self.rows = rows
        self.footnote = footnote
        self.show_keys = False

    def compose(self):
        with Vertical():
            yield Static(self.title_text, classes="title", markup=False)
            yield Static(self.table(), id="rows", markup=False)
            yield Static(self.hint(), classes="hint", id="hint", markup=False)

    def table(self):
        width = max((len(label) for label, _, _, _ in self.rows), default=0)
        parts = []
        for label, detail, key, style in self.rows:
            parts.append((f"{label:<{width}}", style))
            if detail:
                parts.append((f"  {detail}", TONE["muted"]))
            if self.show_keys and key:
                parts.append((f"\n{key}", TONE["muted"]))
            parts.append("\n")
        return Content.assemble(*parts[:-1])

    def hint(self):
        parts = ["Esc close"]
        if any(key for _, _, key, _ in self.rows):
            parts.append("k hide keys" if self.show_keys else "k show keys")
        if self.show_keys and self.footnote:
            parts.append(self.footnote)
        return "  ·  ".join(parts)

    def action_toggle_keys(self):
        self.show_keys = not self.show_keys
        self.query_one("#rows", Static).update(self.table())
        self.query_one("#hint", Static).update(self.hint())


@dataclass(frozen=True)
class Entry:
    """One row of the switcher."""
    section: str
    title: str
    badge: str
    shortcut: str
    help: str
    callback: object


class Switcher(ModalScreen):
    """Ctrl+K: chats and actions in sections, filtered as you type, shortcuts at the right. Enter picks."""

    DEFAULT_CSS = """
    Switcher { align: center top; background: $background 60%; }
    Switcher > Vertical { width: 64; max-width: 90%; height: auto; margin-top: 4; padding: 1 2; background: $surface; border: round $panel; }
    Switcher Input, Switcher Input:focus { border: none; height: 1; padding: 0; background: $surface; margin-bottom: 1; }
    Switcher OptionList { height: auto; max-height: 24; border: none; padding: 0; background: $surface; }
    Switcher OptionList > .option-list--option-disabled { background: transparent; }
    Switcher OptionList > .option-list--option-highlighted, Switcher OptionList:focus > .option-list--option-highlighted {
        background: $foreground 8%; color: $foreground;
    }
    """
    BINDINGS = [
        Binding("escape", "dismiss", show=False),
        Binding("up", "move(-1)", show=False),
        Binding("down", "move(1)", show=False),
    ]

    def __init__(self, entries):
        super().__init__()
        self.entries = entries

    def compose(self):
        with Vertical():
            yield Input(placeholder="Jump to a chat, or pick an action…", id="query")
            yield OptionList(id="results")

    def on_mount(self):
        self.refill("")
        self.query_one("#query", Input).focus()

    def refill(self, query):
        matcher = Matcher(query) if query.strip() else None
        results = self.query_one("#results", OptionList)
        width = results.content_size.width or 58
        options, section = [], None
        for index, entry in enumerate(self.entries):
            if matcher is not None and matcher.match(f"{entry.title} {entry.help}") <= 0:
                continue
            if entry.section != section:
                if options:
                    options.append(Option("", disabled=True))
                options.append(Option(Content.assemble((entry.section.upper(), TONE["faint"])), disabled=True))
                section = entry.section
            title = matcher.highlight(entry.title) if matcher is not None else Content(entry.title)
            gap = max(width - len(entry.title) - len(entry.badge) - len(entry.shortcut), 2)
            options.append(Option(Content.assemble(
                title, (entry.badge, "bold"), " " * gap, (entry.shortcut, TONE["faint"]), "\n", (entry.help, TONE["muted"])),
                id=str(index)))
        results.set_options(options)
        first = next((position for position, option in enumerate(results.options) if not option.disabled), None)
        if first is not None:
            results.highlighted = first

    @on(Input.Changed, "#query")
    def changed(self, event):
        self.refill(event.value)

    def action_move(self, delta):
        results = self.query_one("#results", OptionList)
        (results.action_cursor_down if delta > 0 else results.action_cursor_up)()

    @on(Input.Submitted, "#query")
    def choose(self, event=None):
        option = self.query_one("#results", OptionList).highlighted_option
        if option is not None and option.id is not None:
            self.dismiss(self.entries[int(option.id)])

    @on(OptionList.OptionSelected, "#results")
    def chosen(self, event):
        self.dismiss(self.entries[int(event.option_id)])


@dataclass
class Prompt:
    """A question the app is asking through the composer."""
    question: str
    hint: str
    answer: object       # async callable taking the text
    complete: object     # word -> candidates


# --- the app: all policy, over dumb widgets and the store ---


class TlxApp(App):
    CSS = """
    #main { height: 1fr; }
    #chats { width: 25; height: 100%; border: none; padding: 1 0 0 0; background: $background;
             background-tint: $foreground 5%; color: $foreground-muted; }
    #chats > .option-list--option-disabled { background: transparent; }
    #chats > .option-list--option-highlighted { background: $foreground 12%; color: $foreground; }
    #chats > .option-list--option-hover { background: $foreground 8%; }
    #gutter { background: $background; background-tint: $foreground 5%; }
    #header { height: 1; padding: 0 1; }
    #log { height: 1fr; padding: 0 1; }
    #composer { height: auto; max-height: 11; margin-top: 1; padding: 1 1; border: none;
                border-top: solid $foreground 15%; background: transparent; }
    #composer:focus { border-top: solid $primary 50%; }
    #status { height: 1; padding: 0 1; color: $foreground-muted; text-wrap: nowrap; text-overflow: ellipsis; }
    #log, #composer, Switcher OptionList { scrollbar-gutter: stable; }
    #log, #composer, #chats, Switcher OptionList {
        scrollbar-size: 1 1; scrollbar-background: transparent; scrollbar-background-hover: transparent;
        scrollbar-background-active: transparent; scrollbar-color: $foreground 15%;
        scrollbar-color-hover: $foreground 30%; scrollbar-color-active: $foreground 45%;
    }
    """
    ENABLE_COMMAND_PALETTE = False
    BINDINGS = [
        Binding("escape", "escape", "Read / write"),
        Binding("ctrl+k,ctrl+p", "switcher", "Chats & actions"),
        Binding("alt+down,ctrl+down", "chat(1)", "Next chat", priority=True, show=False),
        Binding("alt+up,ctrl+up", "chat(-1)", "Previous chat", priority=True, show=False),
        Binding("ctrl+q", "quit", "Quit", priority=True),
    ] + [Binding(f"alt+{number}", f"jump({number})", show=False) for number in range(1, 10)]

    def __init__(self, store, daemon=None):
        super().__init__()
        self.store = store
        self.daemon = daemon
        self.daemon_stopped = False
        self.chats = []
        self.names = {}
        self.drafts = {}          # chats started here whose recipients the daemon has not seen yet
        self.nudged = set()       # chats whose unnamed-contact nudge was already shown
        self.active_id = None
        self.prompt = None
        self.hint = ""
        self.new_below = False
        self.previous = None      # (sender, claimed_at) of the last row built, for grouping
        self.read_marker = 0
        self.new_line = None
        self.line_pending = False
        self.oldest_loaded = None
        self.has_older = False
        self.loading_older = False
        self.status = None
        self.commands = {"new": self.command_new, "topic": self.command_topic, "alias": self.command_alias,
                         "who": self.command_who, "theme": self.command_theme, "quit": lambda args: self.exit()}

    def compose(self):
        with Horizontal(id="main"):
            yield ChatList(id="chats")
            yield Gutter(id="gutter", markup=False)
            with Vertical():
                yield Static(id="header", markup=False)
                yield MessageLog(id="log")
                yield Composer(self.completions, id="composer")
                yield Static(id="status", markup=False)

    async def on_mount(self):
        self.chat_list = self.query_one("#chats", ChatList)
        self.header = self.query_one("#header", Static)
        self.log_view = self.query_one("#log", MessageLog)
        self.composer = self.query_one("#composer", Composer)
        self.status = self.query_one("#status", Static)
        self.theme = self.store.setting("theme", "textual-dark")
        self.last_sequence = self.store.last_sequence()
        self.version = self.store.data_version()
        self.refresh_all()
        if self.chats:
            self.chat_list.highlight(max(self.chats, key=lambda chat: chat.last_sequence).id)
        else:
            await self.log_view.show([Static(self.welcome(), markup=False)])
        self.composer.focus()
        self.set_interval(0.2, self.poll)

    def welcome(self):
        return Content.assemble(("Your key, for people who want to reach you:\n", "bold"), (self.store.me, TONE["muted"]),
                                "\n\nWhoever runs the relay adds it to the members. Then start a chat with someone's key: ",
                                ("/new AAAAC3Nza…", "bold"), ("  or Ctrl+K", TONE["muted"]))

    # --- names ---

    def name_of(self, public_key):
        if public_key in self.names:
            return self.names[public_key]
        return "me" if public_key == self.store.me else fingerprint(public_key)[:8]

    def named(self, public_key):
        return public_key in self.names or public_key == self.store.me

    def sender_color(self, public_key):
        return color_of(public_key, light_theme=self.theme.endswith("light"))

    def people(self, chat):
        return ", ".join(map(self.name_of, chat.participants)) or "only me"

    def chat_name(self, chat):
        tag = chat_tag(chat.id)
        if not tag:
            return self.people(chat)
        shared = sum(1 for other in self.chats if chat_tag(other.id) == tag) > 1
        return f"#{tag}" + (f"·{chat.id.partition('@')[2][:4]}" if shared else "")

    def resolve(self, word):
        """A name, a full public key, or a unique prefix of a fingerprint, to a public key."""
        for public_key, name in self.names.items():
            if name == word:
                return public_key
        if len(word) > 40:
            return word
        matches = [key for key in self.store.known_keys() if fingerprint(key).startswith(word)]
        return matches[0] if len(matches) == 1 else None

    def resolve_people(self, words):
        """Public keys for the words, or None after telling the user which ones are unknown."""
        keys = [self.resolve(word) for word in words]
        unknown = [word for word, key in zip(words, keys) if key is None]
        if unknown or not keys:
            self.notify(f"unknown: {' '.join(unknown)}" if unknown else f"{WHO[0]}  {WHO[1]}", severity="error")
            return None
        return list(dict.fromkeys(keys))

    def name_candidates(self, word):
        return [name for name in sorted(self.names.values()) if name.startswith(word)]

    def contact_candidates(self, word):
        """Contacts to alias: the open chat's first, then everyone known, by name or fingerprint."""
        chat = self.current_chat()
        for keys in (chat.participants if chat else (), self.store.known_keys()):
            names = dict.fromkeys(self.name_of(key) for key in keys if key != self.store.me)
            matches = [name for name in names if name.startswith(word)]
            if matches:
                return matches
        return []

    # --- rows of the log ---

    def row(self, sender, claimed_at, body, row_id, pending=False):
        """A message row, grouped under the previous one when it is the same sender within minutes."""
        grouped = (self.previous is not None and self.previous[0] == sender
                   and 0 <= claimed_at - self.previous[1] < GROUP_WINDOW_NS)
        if grouped:
            content = Content(body)
        else:
            name_tone = "bold " + (self.sender_color(sender) if self.named(sender) else "italic " + TONE["muted"])
            content = Content.assemble((self.name_of(sender), name_tone), "\n", body)
        return MessageRow(content, when(claimed_at), id=row_id, group=not grouped, pending=pending)

    def rows_for(self, message):
        """The message's row, preceded by the new-messages line when reading left off just before it."""
        rows = []
        if (self.line_pending and self.new_line is None and message.sequence > self.read_marker
                and message.sender != self.store.me):
            self.new_line = NewLine()
            rows.append(self.new_line)
        rows.append(self.row(message.sender, message.claimed_at, render_body(message.body), f"m{message.sequence}"))
        self.previous = (message.sender, message.claimed_at)
        return rows

    def pending_rows(self, chat_id):
        """Outbox rows look exactly like the message they will become; only the time column shows the state,
        so nothing rewraps when the echo replaces them."""
        rows = []
        for pending in self.store.pending(chat_id):
            row = self.row(self.store.me, pending.claimed_at, render_body(pending.body), f"p{pending.claimed_at}", pending=True)
            if pending.error:
                row.when = Content.assemble(("✗", "$error"))
                row.body = Content.assemble(row.body, (f"\n✗ {pending.error}", "$error"))
            else:
                row.when = Content.assemble(("✓" if pending.sent else "…", TONE["faint"]))
            rows.append(row)
        return rows

    # --- what is on screen ---

    def refresh_all(self):
        self.refresh_chats()
        self.refresh_header()
        self.refresh_status()

    def refresh_chats(self):
        chats = self.store.chats()
        known = {chat.id for chat in chats}
        for chat in chats:
            if chat.participants:
                self.drafts.pop(chat.id, None)
        chats = [replace(chat, participants=tuple(self.drafts[chat.id]))
                 if chat.id in self.drafts and not chat.participants else chat for chat in chats]
        chats += [Chat(chat_id, 0, 0, 0, tuple(recipients)) for chat_id, recipients in self.drafts.items()
                  if chat_id not in known]
        ordered = [chat for chat in chats if not chat_tag(chat.id)] + [chat for chat in chats if chat_tag(chat.id)]
        self.chats = [replace(chat, number=number) for number, chat in enumerate(ordered, 1)]
        self.names = self.store.aliases()
        self.chat_list.set_chats(self.chats, self.chat_name, self.active_id)
        if self.status is not None:
            self.draw_gutter()

    def refresh_header(self):
        chat = self.current_chat()
        if chat is None:
            self.header.update(Content.assemble(("No chats yet", "bold")))
            self.composer.placeholder = "Start a chat: /new KEY, or Ctrl+K"
            return
        name = self.chat_name(chat)
        detail = f"   {self.people(chat)}" if chat_tag(chat.id) else ""
        self.header.update(Content.assemble((name, "bold"), (detail, TONE["muted"])))
        self.composer.placeholder = self.prompt.hint if self.prompt else f"Message {name}"

    def refresh_status(self):
        """One line, one thing at a time: the most pressing wins."""
        chat = self.current_chat()
        if self.daemon_stopped:
            text = f"tlxd stopped with exit code {self.daemon.returncode}; see tlxd.log next to your key"
        elif self.prompt:
            text = Content.assemble((self.prompt.question, "bold"), ("  ·  Esc cancels", TONE["faint"]))
        elif self.hint:
            text = self.hint
        elif chat is None:
            text = "No chats yet. Ctrl+K, or /new KEY to start one."
        else:
            parts = []
            pendings = self.store.pending(chat.id)
            failed = [pending for pending in pendings if pending.error]
            if chat.id in self.drafts:
                parts.append(f"New chat with {self.people(chat)}: Enter sends the first message")
            if failed:
                parts.append(f"{len(failed)} failed  ·  Esc, then r to retry or d to discard")
            elif pendings:
                parts.append(f"{len(pendings)} pending")
            if self.new_below:
                parts.append("↓ new messages")
            unnamed = [key for key in chat.participants if key not in self.names]
            if unnamed and chat.id not in self.nudged:
                short = fingerprint(unnamed[0])[:8]
                parts.append(f"Unnamed contact {short}: /alias {short} NAME")
            text = "  ·  ".join(parts) if parts else fit(KEY_HINTS, self.status.content_size.width or 200)
        self.status.update(text)

    def current_chat(self):
        return next((chat for chat in self.chats if chat.id == self.active_id), None)

    # --- keeping up with the daemon ---

    async def poll(self):
        if self.daemon is not None and self.daemon.poll() is not None and not self.daemon_stopped:
            self.daemon_stopped = True
            self.notify(f"tlxd stopped with exit code {self.daemon.returncode}", severity="error", timeout=30)
            self.refresh_status()
        version = self.store.data_version()
        if version != self.version:
            self.version = version
            await self.sync()
        self.settle_read()
        if (self.has_older and not self.loading_older and self.log_view.max_scroll_y > 0
                and self.log_view.scroll_y == 0):
            await self.load_older()

    async def sync(self):
        pinned = self.log_view.is_vertical_scroll_end
        caught_up = pinned and self.read_marker >= self.last_sequence
        for message in self.store.messages_after(self.last_sequence):
            self.last_sequence = message.sequence
            if message.chat_id == self.active_id:
                if caught_up:
                    await self.dismiss_new_line()
                for row in self.rows_for(message):
                    await self.log_view.append(row)
                if not pinned and message.sender != self.store.me:
                    self.new_below = True
        if self.active_id is not None:
            await self.log_view.reconcile_pending(self.pending_rows(self.active_id))
        self.refresh_all()

    def settle_read(self):
        """Reading the bottom of the open chat is what marks it read."""
        chat = self.current_chat()
        if chat is None or not self.log_view.is_vertical_scroll_end:
            return
        if self.new_below:
            self.new_below = False
            self.refresh_status()
        if chat.last_sequence > self.read_marker:
            self.read_marker = chat.last_sequence
            self.store.mark_read(chat.id, chat.last_sequence)
            self.refresh_chats()

    async def dismiss_new_line(self):
        """The line marks where reading left off; once the reader has caught up it only misleads."""
        if self.new_line is not None:
            await self.new_line.remove()
            self.new_line = None

    async def open_chat(self, chat_id):
        if self.active_id is not None and self.active_id != chat_id:
            self.nudged.add(self.active_id)
        self.active_id = chat_id
        self.new_below = False
        self.previous = None
        self.new_line = None
        self.read_marker = self.store.last_read(chat_id)
        self.has_older, self.loading_older = False, False
        messages = self.store.messages(chat_id, PAGE)
        more = len(messages) == PAGE
        self.oldest_loaded = messages[0].sequence if messages else None
        # the line is only honest when the boundary is inside what is shown, or everything is shown
        self.line_pending = not more or any(message.sequence <= self.read_marker for message in messages)
        rows = [row for message in messages for row in self.rows_for(message)]
        self.line_pending = False      # only an opening places the line; live messages never do
        rows += self.pending_rows(chat_id)
        await self.log_view.show(rows, scroll_to=self.new_line)
        self.has_older = more
        self.refresh_all()

    async def load_older(self):
        """One more page above what is shown, once the reader reaches the top."""
        self.loading_older = True
        try:
            older = self.store.messages(self.active_id, PAGE, before=self.oldest_loaded)
            self.has_older = len(older) == PAGE
            if older:
                newest, self.previous = self.previous, None
                rows = [row for message in older for row in self.rows_for(message)]
                self.previous = newest
                self.oldest_loaded = older[0].sequence
                await self.log_view.prepend(rows)
        finally:
            self.loading_older = False

    # --- input ---

    @on(OptionList.OptionHighlighted, "#chats")
    async def chat_highlighted(self, event):
        """A click, or a highlight set outside select_chat: the rest of the switch still lands in one frame."""
        with self.batch_update():
            self.draw_gutter()
            if event.option_id != self.active_id:
                await self.open_chat(event.option_id)

    @on(Composer.Changed, "#composer")
    def composer_changed(self, event):
        """Under a half-typed command, say what it is and what the next argument asks for."""
        self.hint = ""
        line = event.text_area.text.split("\n")[0]
        if line.startswith("/") and not self.prompt:
            words = line[1:].split(" ")
            matches = [name for name in USAGE if name.startswith(words[0])]
            if len(words) > 1 and words[0] in QUESTIONS:
                question, hint = QUESTIONS[words[0]][min(len(words) - 2, len(QUESTIONS[words[0]]) - 1)]
                self.hint = f"{question}  {hint}"
            elif len(matches) == 1:
                self.hint = "  ".join(USAGE[matches[0]])
            else:
                self.hint = "  ".join(f"/{name}" for name in matches) if matches else f"unknown command: /{words[0]}"
        self.refresh_status()

    @on(Composer.Completions)
    def show_completions(self, event):
        parts = []
        for index, candidate in enumerate(event.candidates):
            parts += [(candidate, "bold" if index == event.index else TONE["muted"]), "   "]
        self.hint = Content.assemble(*parts[:-1])
        self.refresh_status()

    def completions(self, line, start, word):
        """Candidates for the word at the cursor: the prompt's, a command name, or the argument's."""
        if self.prompt:
            return self.prompt.complete(word)
        if not line.startswith("/"):
            return self.name_candidates(word)
        if start == 0:
            return [f"/{name}" for name in USAGE if name.startswith(word[1:])]
        command, position = line[1:].split(" ")[0], line[:start].count(" ") - 1
        if command == "alias" and position == 0:
            return self.contact_candidates(word)
        if command == "new" or (command == "topic" and position >= 1):
            return self.name_candidates(word)
        return []

    @on(Composer.Submitted)
    async def composer_submitted(self, event):
        text = event.value
        if not text.strip():
            return
        self.composer.clear()
        if self.prompt:
            await self.prompt.answer(text.strip())
        elif text.startswith("/"):
            name, *args = text.split("\n")[0][1:].split()
            await self.commands.get(name, self.command_help)(args)
        elif self.active_id is None:
            self.notify("No chat is open. Start one with /new KEY, or Ctrl+K", severity="warning")
            self.composer.value = text
        else:
            self.store.send(self.active_id, text.encode(), self.drafts.get(self.active_id))
            await self.dismiss_new_line()
            await self.sync()
            self.log_view.scroll_end(animate=False)

    async def on_key(self, event):
        """Reading mode keys, and any other typing goes to the composer."""
        focused = self.focused
        if focused is None or focused is self.composer:
            return
        if event.key == "enter":
            self.composer.focus()
        elif not event.is_printable:
            return
        elif focused is self.log_view and event.character in "jkgG":
            if event.character == "g":
                self.log_view.scroll_home(animate=False)
            elif event.character == "G":
                self.log_view.scroll_end(animate=False)
            else:
                self.log_view.scroll_relative(y=3 if event.character == "j" else -3, animate=False)
        elif focused is self.log_view and event.character in "rd" and self.active_id is not None:
            await self.resolve_failed(retry=event.character == "r")
        else:
            self.composer.focus()
            self.composer.insert(event.character)
        event.stop()

    async def resolve_failed(self, retry):
        failed = [pending for pending in self.store.pending(self.active_id) if pending.error]
        if not failed:
            self.notify("Nothing has failed.")
            return
        for pending in failed:
            (self.store.retry if retry else self.store.discard)(pending.claimed_at)
        self.notify(f"{len(failed)} message{'s' if len(failed) > 1 else ''} {'queued again' if retry else 'discarded'}")
        await self.sync()

    def on_resize(self, event):
        if self.status is not None:
            self.refresh_chats()
            self.refresh_status()

    @on(Composer.Reshaped)
    def draw_gutter(self, event=None):
        gutter = self.query_one("#gutter", Gutter)
        highlight_row = None
        if self.chat_list.highlighted is not None:
            highlight_row = (self.chat_list.content_region.y + self.chat_list.highlighted
                             - self.chat_list.scroll_offset.y - gutter.region.y)
        gutter.draw(self.composer.region.y - gutter.region.y,
                    "$primary 50%" if self.composer.has_focus else "", highlight_row)

    def action_escape(self):
        if self.prompt:
            self.end_prompt()
        else:
            (self.log_view if self.focused is self.composer else self.composer).focus()

    async def select_chat(self, chat_id):
        """Switch in one frame: the sidebar's highlight, the gutter and the messages repaint together."""
        with self.batch_update():
            self.chat_list.highlight(chat_id)
            self.draw_gutter()
            if chat_id != self.active_id:
                await self.open_chat(chat_id)

    async def action_chat(self, delta):
        if self.chats:
            ids = [chat.id for chat in self.chats]
            current = ids.index(self.active_id) if self.active_id in ids else -1
            await self.select_chat(ids[(current + delta) % len(ids)])

    async def action_jump(self, number):
        if number <= len(self.chats):
            await self.select_chat(self.chats[number - 1].id)

    def action_switcher(self):
        if not isinstance(self.screen, Switcher):
            self.push_screen(Switcher(list(self.entries())), callback=self.chosen)

    async def chosen(self, entry):
        if entry is not None:
            await entry.callback()
        self.composer.focus()

    def entries(self):
        for chat in sorted(self.chats, key=lambda chat: (chat.unread == 0, -chat.last_sequence)):
            yield Entry("Chats", self.chat_name(chat), f"  {chat.unread} unread" if chat.unread else "",
                        f"Alt+{chat.number}" if chat.number <= 9 else "", self.people(chat),
                        partial(self.jump_to, chat.id))
        yield Entry("Actions", "Next chat", "", "Alt+↓", "", partial(self.step_chat, 1))
        yield Entry("Actions", "Previous chat", "", "Alt+↑", "", partial(self.step_chat, -1))
        other = "light" if self.theme == "textual-dark" else "dark"
        for title, name, shortcut in (("New chat…", "new", "/new"), ("New topic…", "topic", "/topic"),
                                      ("Alias a contact…", "alias", "/alias"), ("Who is in this chat", "who", "/who"),
                                      (f"Switch to the {other} theme", "theme", "/theme")):
            yield Entry("Actions", title, "", shortcut, USAGE[name][1], partial(self.commands[name], []))
        yield Entry("Actions", "Quit", "", "Ctrl+Q", "", self.commands["quit"])

    async def jump_to(self, chat_id):
        await self.select_chat(chat_id)

    async def step_chat(self, delta):
        await self.action_chat(delta)

    # --- commands, each also usable as a guided prompt ---

    def ask(self, question, answer, complete=lambda word: []):
        self.prompt = Prompt(question[0], question[1], answer, complete)
        self.composer.clear()
        self.refresh_header()
        self.refresh_status()
        self.composer.focus()

    def end_prompt(self):
        self.prompt = None
        self.composer.clear()
        self.refresh_header()
        self.refresh_status()

    def ask_people(self, then):
        async def answer(text):
            keys = self.resolve_people(text.split())
            if keys is not None:
                self.end_prompt()
                await then(keys)
        self.ask(WHO, answer, self.name_candidates)

    async def start_chat(self, tag, keys):
        chat_id = (f"{tag}@" if tag else "@") + secrets.token_hex(8)
        self.drafts[chat_id] = keys
        self.refresh_chats()
        self.chat_list.highlight(chat_id)
        self.composer.focus()

    async def command_new(self, args):
        if args:
            keys = self.resolve_people(args)
            if keys is not None:
                await self.start_chat("", keys)
        else:
            self.ask_people(partial(self.start_chat, ""))

    async def command_topic(self, args):
        async def named(text):
            name = text.split()[0].strip("#@")
            if not name:
                return
            self.end_prompt()
            self.ask_people(partial(self.start_chat, name))
        if len(args) >= 2:
            keys = self.resolve_people(args[1:])
            if keys is not None:
                await self.start_chat(args[0].strip("#@"), keys)
        elif args:
            self.ask_people(partial(self.start_chat, args[0].strip("#@")))
        else:
            self.ask(QUESTIONS["topic"][0], named)

    async def command_alias(self, args):
        async def set_alias(public_key, name):
            try:
                self.store.set_alias(public_key, name.split()[0])
            except sqlite3.IntegrityError:
                self.notify(f"{name} already names another contact", severity="error")
                return
            self.refresh_chats()
            if self.active_id:
                await self.open_chat(self.active_id)

        def ask_name(public_key):
            async def answer(text):
                self.end_prompt()
                await set_alias(public_key, text)
            self.ask(QUESTIONS["alias"][1], answer)

        async def which(text):
            public_key = self.resolve(text.split()[0])
            if public_key is None:
                self.notify(f"unknown contact: {text}", severity="error")
                return
            ask_name(public_key)

        if len(args) >= 2:
            public_key = self.resolve(args[0])
            if public_key is None:
                self.notify(f"unknown contact: {args[0]}", severity="error")
            else:
                await set_alias(public_key, args[1])
        elif args:
            await which(args[0])
        else:
            self.ask(QUESTIONS["alias"][0], which, self.contact_candidates)

    async def command_who(self, args):
        chat = self.current_chat()
        rows = [("me", "you", self.store.me, f"bold {self.sender_color(self.store.me)}")]
        for key in (chat.participants if chat else ()):
            short = fingerprint(key)[:8]
            detail = "" if key in self.names else f"unnamed  ·  /alias {short} NAME"
            rows.append((self.name_of(key), detail, key, f"bold {self.sender_color(key)}"))
        if chat is None:
            title = Content.assemble(("You", "bold"))
        else:
            title = Content.assemble((self.chat_name(chat), "bold"), (f"  ·  {len(rows)} people", TONE["muted"]))
        self.push_screen(Sheet(title, rows, footnote=chat.id if chat else ""))

    async def command_theme(self, args):
        self.theme = "textual-light" if self.theme == "textual-dark" else "textual-dark"
        self.store.set_setting("theme", self.theme)
        if self.active_id is not None:
            await self.open_chat(self.active_id)      # names take the palette lit for the new background

    async def command_help(self, args):
        rows = [(usage, help, "", "") for usage, help in USAGE.values()]
        rows += [("", "", "", ""), ("Keys", "", "", "bold")] + [(key, does, "", "") for key, does in KEYS]
        self.push_screen(Sheet(Content.assemble(("Commands and keys", "bold")), rows))


def start_daemon(directory, host, port):
    """Run tlxd for this directory; its output goes to tlxd.log there."""
    with open(directory / "tlxd.log", "ab") as log:
        return subprocess.Popen([sys.executable, "-u", str(Path(__file__).with_name("tlxd.py")),
                                 "--dir", str(directory), "--host", host, "--port", str(port)],
                                stdout=log, stderr=subprocess.STDOUT)


def daemon_ready(database_path):
    """True once tlxd has created its tables. Opens read-only so no empty file appears."""
    try:
        connection = sqlite3.connect(database_path.resolve().as_uri() + "?mode=ro", uri=True)
    except sqlite3.OperationalError:
        return False
    try:
        return connection.execute("select count(*) from sqlite_master where name = 'outbox'").fetchone()[0] == 1
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description="Chat over the database tlxd keeps in sync.")
    parser.add_argument("--dir", type=Path, default=Path("~/.tlx"),
                        help="directory holding your key.pub, tlxd's database and this client's, default ~/.tlx")
    parser.add_argument("--host", help="relay address; when given, tlxd is started from here and stopped on exit")
    parser.add_argument("--port", type=int, default=2222, help="relay SSH port for --host, default 2222")
    args = parser.parse_args()

    directory = args.dir.expanduser()
    try:
        own_public_key = (directory / "key.pub").read_text().split()[1]
    except (OSError, IndexError):
        sys.exit(f"cannot read a public key from {directory / 'key.pub'}: see the quickstart in README.md")

    database_path = directory / "tlxd.db"
    daemon = None
    if args.host:
        daemon = start_daemon(directory, args.host, args.port)
        deadline = time.monotonic() + 15
        while not daemon_ready(database_path):
            if daemon.poll() is not None or time.monotonic() > deadline:
                if daemon.poll() is None:
                    daemon.terminate()
                log = (directory / "tlxd.log").read_text(errors="replace").splitlines()[-5:]
                sys.exit("tlxd did not start:\n" + "\n".join(log))
            time.sleep(0.1)
    elif not daemon_ready(database_path):
        sys.exit(f"{database_path} has no tables yet: start tlxd first, or pass --host to start it from here")

    try:
        TlxApp(Store(directory / "tui.db", database_path, own_public_key), daemon).run()
    finally:
        if daemon is not None and daemon.poll() is None:
            daemon.terminate()
            daemon.wait(timeout=5)


if __name__ == "__main__":
    main()
