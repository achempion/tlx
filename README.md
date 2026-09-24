# tlx

Encrypted messaging you can actually understand.

Communicate with people you trust, away from the eyes of modern surveillance and large corporations.

tlx is the smallest possible end-to-end encrypted messaging stack: a relay that
stores what it can't read, and a daemon, `tlxd`, that syncs a local SQLite database with it.
Build anything on top: a TUI, a desktop app, a bot, a script.

- **No new crypto.** SSH keys for identity, SSH for transport, age for encryption,
  SSH signatures for authorship.
- **Small enough to audit.** The relay and `tlxd` are each under 200 lines with zero dependencies.
- **A server that knows nothing.** The relay sees encrypted blobs and who to
  deliver them to, never content or chats.
- **Chats without a server.** A chat is just its signed member list; clients
  derive it themselves.

## Architecture

| Component | What it does                                                                              |
|-----------|-------------------------------------------------------------------------------------------|
| `relay`   | SSH-only mailbox: `put` a blob into inboxes, `get` yours by sequence                      |
| `tlxd`    | Syncs SQLite with the relay: signs and sends the outbox; verifies and stores new messages |
| `tui`     | Example UI: reads messages, writes the outbox                                             |

## Relay

A mailbox over SSH. Each member has an inbox.

### Run

```bash
docker run -d --name tlx -p 2222:22 \
  -e TLX_MEMBERS="AAAAC3Nza... AAAAC3Nza..." \
  -v tlx-ssh:/etc/ssh -v tlx-home:/home/tlx \
  achempion/tlx-relay
```

`TLX_MEMBERS` is a space-separated list of public keys. Get a key with `cut -d' ' -f2 ~/.ssh/id_ed25519.pub`.

### Use

`203.0.113.10` is an example address. Replace it with the address of your relay.

```bash
ME=AAAAC3Nza...      # your public key
BOB=AAAAC3Nza...     # Bob's public key

# a new chat gets a random id; a topic also gets a tag: launch@<id>
# replies reuse the chat word exactly as received
CHAT="@$(openssl rand -hex 8)"

# message: chat and recipients' keys on the first line, then the body
printf '%s %s %s\nhello\n' "$CHAT" "$ME" "$BOB" > message

# to send an image (up to 1 MB), put the file after the first line instead
# { echo "$CHAT $ME $BOB"; cat photo.jpg; } > message

# sign it (creates message.sig)
ssh-keygen -Y sign -f ~/.ssh/tlx_ed25519 -n chat message

# encrypt message + signature for every recipient, then deliver
cat message message.sig \
  | age -r "ssh-ed25519 $ME" -r "ssh-ed25519 $BOB" \
  | ssh -i ~/.ssh/tlx_ed25519 -p 2222 tlx@203.0.113.10 put $ME $BOB

# print blobs newer than LAST_SEEN_SEQUENCE, waiting up to 60 s
ssh -i ~/.ssh/tlx_ed25519 -p 2222 tlx@203.0.113.10 get 0
```

### Receive new messages

Decrypts new messages as they arrive and reconnects after each wait (bash):

```bash
seq=0
while true; do
  while read -r n size; do
    dd bs=1 count="$size" 2>/dev/null | age -d -i ~/.ssh/id_ed25519 | cat -v
    seq=$n
  done < <(ssh -i ~/.ssh/id_ed25519 -p 2222 tlx@203.0.113.10 get "$seq")
  sleep 1
done
```

## tlxd

Keeps `tlx.db` in sync with the relay. Needs `ssh`, `ssh-keygen` and `age`.

```bash
TLX_RELAY=tlx@203.0.113.10 TLX_PORT=2222 python3 tlxd.py
```

To send, insert into `outbox`. New messages appear in `messages`.

```bash
sqlite3 tlx.db "insert into outbox (members, body) values ('$BOB', 'hello')"
sqlite3 tlx.db "select time, sender, body from messages"
```
