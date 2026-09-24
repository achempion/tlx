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

| Component | What it does                                                         |
|-----------|----------------------------------------------------------------------|
| `relay`   | SSH-only mailbox: `put` a blob into inboxes, `get` yours by sequence |
| `sync`    | Signs, encrypts, sends; fetches, verifies, stores in SQLite          |
| `tui`     | Example client: reads the database, writes the outbox                |

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
ALICE=AAAAC3Nza...   # Alice's public key
BOB=AAAAC3Nza...     # Bob's public key

# encrypt for Alice and Bob, then deliver to both inboxes
echo hello \
  | age -r "ssh-ed25519 $ALICE" -r "ssh-ed25519 $BOB" \
  | ssh -i ~/.ssh/id_ed25519 -p 2222 tlx@203.0.113.10 put $ALICE $BOB

# to send an image (up to 1 MB), encrypt the file instead
age -r "ssh-ed25519 $ALICE" -r "ssh-ed25519 $BOB" < photo.jpg \
  | ssh -i ~/.ssh/id_ed25519 -p 2222 tlx@203.0.113.10 put $ALICE $BOB

# print blobs newer than LAST_SEEN_SEQUENCE, waiting up to 60 s
ssh -i ~/.ssh/id_ed25519 -p 2222 tlx@203.0.113.10 get 0
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
