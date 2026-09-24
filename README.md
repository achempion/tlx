# tlx

Encrypted messaging you can actually understand.

Communicate with people you trust, away from the eyes of modern surveillance and large corporations.

tlx is the smallest possible end-to-end encrypted messaging stack: a relay that
stores what it can't read, and a sync that keeps a local SQLite database current.
Build any client on top: a TUI, a desktop app, a bot, a script.

- **No new crypto.** SSH keys for identity, SSH for transport, age for encryption,
  SSH signatures for authorship.
- **Small enough to audit.** The relay and sync are each under 200 lines with zero dependencies.
- **A server that knows nothing.** The relay sees encrypted blobs and who to
  deliver them to, never content or chats.
- **Chats without a server.** A chat is just its signed member list; clients
  derive it themselves.

## Architecture

| Component | What it does                                                       |
|-----------|--------------------------------------------------------------------|
| `relay`   | SSH-only mailbox: `put` a blob into inboxes, `get` yours by cursor |
| `sync`    | Signs, encrypts, sends; fetches, verifies, stores in SQLite        |
| `tui`     | Example client: reads the database, writes the outbox              |

## Relay

Relay is a mailbox where every participant can upload an
