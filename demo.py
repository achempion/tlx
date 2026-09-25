#!/usr/bin/env python3
"""Build a folder for a tui.py screenshot: a small lighting studio a week before a trade fair.

The databases are written directly, the way tlxd leaves them after a sync; no relay or encryption is involved.
Run it again after editing the messages: the keys are kept, so everyone keeps their color.
"""

import argparse
import hashlib
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import tlxd  # noqa: E402
import tui  # noqa: E402

MARKER = ".tlx-demo"
PEOPLE = ["me", "Maya", "Tom", "Lena", "Dev", "Priya"]

# name: (topic tag, or "" for a chat; everyone in it besides me)
CHATS = {
    "lena": ("", ["Lena"]),
    "planning": ("", ["Maya", "Tom"]),
    "priya": ("", ["Priya"]),
    "milan": ("milan", ["Maya", "Tom", "Lena", "Dev"]),
    "hiring": ("hiring", ["Maya", "Lena"]),
    "shop": ("shop", ["Dev", "Priya", "Maya"]),
}

# How many of a chat's last messages are still unread.
UNREAD = {"priya": 1, "shop": 2}

YESTERDAY, TODAY = -1, 0

# (day, time, chat, sender, text), in the order the relay delivered them.
MESSAGES = [
    (YESTERDAY, "12:10", "lena", "Lena", "can I borrow the good camera for the catalogue shoot on thursday?"),
    (YESTERDAY, "12:31", "lena", "me", "yes, it's in the cabinet. battery is charged"),
    (YESTERDAY, "12:32", "lena", "Lena", "thanks"),
    (YESTERDAY, "16:20", "milan", "Tom", "courier confirmed. five crates, pickup on the 12th at 8"),
    (YESTERDAY, "16:24", "milan", "Maya", "good"),
    (YESTERDAY, "17:05", "hiring", "Maya", "shortlist for the studio assistant is down to 4. interviews tuesday and wednesday"),
    (YESTERDAY, "17:20", "hiring", "Lena", "I can do tuesday afternoon"),
    (YESTERDAY, "17:22", "hiring", "me", "wednesday morning for me"),
    (TODAY, "08:52", "planning", "Maya", "can we move friday's planning to monday? I'm at the bank friday morning"),
    (TODAY, "09:03", "planning", "Tom", "monday works"),
    (TODAY, "09:10", "planning", "me", "monday 10:00 then"),
    (TODAY, "09:15", "shop", "Dev", "3 orders overnight, one from Oslo"),
    (TODAY, "09:16", "shop", "Dev", "the Oslo one wants two Arc lamps. told them 3 weeks"),
    (TODAY, "09:30", "priya", "Priya", "sent you the new price list. Arc goes up 40, everything else stays"),
    (TODAY, "10:41", "milan", "Tom", "glass supplier just called. shades for the Arc lamps ship on the 14th, not the 7th"),
    (TODAY, "10:42", "milan", "Lena", "the fair opens on the 16th"),
    (TODAY, "10:42", "milan", "Tom", "yep"),
    (TODAY, "10:44", "milan", "Maya", "how many are ready now"),
    (TODAY, "10:45", "milan", "Tom", "9 of 24"),
    (TODAY, "10:47", "shop", "Priya", "someone asked again if the Low lamp comes in green. third time this month"),
    (TODAY, "10:47", "milan", "Dev", "courier needs everything by the 12th. the 14th only works if we drive it to Milan ourselves"),
    (TODAY, "10:47", "milan", "Lena", "that's 11 hours each way"),
    (TODAY, "10:48", "milan", "Dev", "I know"),
    (TODAY, "10:52", "milan", "Maya", "do we need all 24 on the stand? or just enough to show and take orders"),
    (TODAY, "10:53", "milan", "Lena", "the wall was designed for 24. with 9 it looks half empty"),
    (TODAY, "10:58", "priya", "Priya", "can you approve it before 3? the shop update goes out at 4"),
    (TODAY, "10:58", "milan", "me", "put the 9 on the wall, lit, and the bare brass bases on the table. "
                                    "people will ask about them, which is kind of the point"),
    (TODAY, "11:01", "milan", "Lena", "honestly that could look good. I'll mock it up tonight"),
    (TODAY, "11:05", "shop", "Dev", "2 more since this morning"),
    (TODAY, "11:06", "milan", "Maya", "ok. 9 ship on the 12th, no road trip. Lena does the layout, "
                                      "Tom tells the supplier we still want all 24"),
    (TODAY, "11:07", "milan", "Tom", "on it"),
    (TODAY, "11:18", "milan", "Dev", "changed the courier booking from five crates to two"),
]


def key_for(path, taken_hues):
    """A key pair at path, made again until its color is a clear step away from everyone's so far.

    Neighbouring hues look alike, so a key is kept only when no one sits next to it on the color wheel;
    when there is no such room left, a hue nobody has will do.
    """
    public_path = path.with_name(path.name + ".pub")
    for attempt in range(200):
        if not path.exists():
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", path], check=True)
        public_key = public_path.read_text().split()[1]
        hue = hashlib.sha256(public_key.encode()).digest()[0] % tui.HUES
        spaced = all((hue - taken) % tui.HUES not in (0, 1, tui.HUES - 1) for taken in taken_hues)
        if spaced or (attempt >= 100 and hue not in taken_hues):
            taken_hues.add(hue)
            return public_key
        path.unlink()
        public_path.unlink()
    sys.exit(f"no free color left for {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", type=Path, default=Path("~/tlx-demo"), help="demo folder, default ~/tlx-demo")
    directory = parser.parse_args().dir.expanduser()

    if directory.exists() and any(directory.iterdir()) and not (directory / MARKER).exists():
        sys.exit(f"{directory} is not empty and was not made by this script; pick another --dir")
    (directory / "contacts").mkdir(parents=True, exist_ok=True)
    (directory / MARKER).touch()
    for name in ["tlxd.db", "tlxd.db-wal", "tlxd.db-shm", "tui.db", "tui.db-wal", "tui.db-shm"]:
        (directory / name).unlink(missing_ok=True)

    taken_hues = set()
    keys = {name: key_for(directory / "key" if name == "me" else directory / "contacts" / name, taken_hues)
            for name in PEOPLE}
    chat_ids = {chat: f"{tag}@{hashlib.sha256(chat.encode()).hexdigest()[:16]}" for chat, (tag, _) in CHATS.items()}

    storage = tlxd.Storage(directory / "tlxd.db", keys["me"])
    today = datetime.now()
    sequences = {chat: [] for chat in CHATS}
    for sequence, (day, clock, chat, sender, text) in enumerate(MESSAGES, 1):
        hour, minute = map(int, clock.split(":"))
        moment = (today + timedelta(days=day)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        claimed_at = int(moment.timestamp()) * 10**9 + sequence
        members = ["me", *CHATS[chat][1]]
        storage.save_message(tlxd.Message(
            sequence=sequence, chat_id=chat_ids[chat], recipient_public_keys=[keys[name] for name in members],
            sender_public_key=keys[sender], claimed_at=claimed_at, relayed_at=claimed_at // 10**9, body=text.encode()))
        sequences[chat].append(sequence)
    storage.connection.close()

    state = sqlite3.connect(directory / "tui.db")
    with state:
        state.executescript(tui.STATE_SCHEMA)
        state.executemany("insert into alias (public_key, name) values (?, ?)",
                          [(keys[name], name) for name in PEOPLE if name != "me"])
        state.executemany("insert into read (chat_id, sequence) values (?, ?)",
                          [(chat_ids[chat], sequences[chat][-1 - UNREAD.get(chat, 0)]) for chat in CHATS])
    state.close()

    print(f"demo ready in {directory}")
    print(f"python3 {ROOT / 'tui.py'} --dir {directory}")


if __name__ == "__main__":
    main()
