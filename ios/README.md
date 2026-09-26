# tlx for iOS

A minimal iOS client, built like the desktop: a sync engine keeps `sync.db` in step with the relay,
and the UI works only with SQLite. The identity is the desktop's `~/.tlx/key`, pasted into the app.

## Build

Needs Xcode with the iOS platform, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Go and
[gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile).

```bash
cd ios
make core project
xcodebuild -project tlx.xcodeproj -scheme tlx -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Run the local-name, conversation, draft, and notification tests with:

```bash
xcodebuild -project tlx.xcodeproj -scheme tlx -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Conversations

Use **New** on the Chats screen to start a chat or a named topic. Choose known contacts or paste
an Ed25519 public key, with or without the `ssh-ed25519` prefix. Each creation makes a separate
conversation; topic names are shared with its participants, while contact aliases stay local.

Creating a conversation sends nothing. Its participants and draft text are saved locally, and it
stays in the chat list while offline. The first message starts the conversation for its recipients.
Unsent conversations can be discarded by swiping their row. Drafts clear only after a message is
queued successfully; delivery failures remain visible in the conversation.

## Background sync and notifications

The engine runs while the app is on screen and lingers for about 25 seconds after it leaves, so a reply
that is about to land still arrives. After that, iOS wakes the app for Background App Refresh whenever it
decides to, usually a few times a day, and one pass fetches new messages; sending stays a foreground activity. Refresh is
opportunistic; it never runs after a force quit, in Low Power Mode, or when Background App Refresh is off in Settings.

With notifications turned on in Settings, which is when the app asks iOS for permission, a message from
someone else that arrives while the app is in the background posts a local notification, named as the chat
list names the chat. Topics stay quiet. Tapping the notification opens the chat, and notifications clear
once their messages have been seen. Nothing leaves the device: there is no push server.

To try a refresh without waiting, pause the app in the debugger and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.achempion.tlx.refresh"]
```

## File structure

```
ios/
├─ project.yml             build definition for XcodeGen; the .xcodeproj is generated, not committed
├─ Info.plist              bundle keys, the launch screen, and the background refresh task
├─ Makefile                make core binds the Go core, make project generates the Xcode project
├─ Sources/
│  ├─ TlxApp.swift         entry point: Settings, the switch between screens, the engine's lifetime and refresh task
│  ├─ Identity.swift       the private key, parsed by the core and kept in the Keychain
│  ├─ Notifications.swift  local notifications for messages that arrive in the background, and taps on them
│  ├─ Sync/                the tlxd port
│  │  ├─ Relay.swift       the relay address, and get and put in tlx terms
│  │  ├─ Storage.swift     sync.db: tlxd's schema, saving messages, the outbox queries
│  │  └─ SyncEngine.swift  decrypt and verify, sign and encrypt, one receive or send pass and the loops over them
│  ├─ Views/               the tui port
│  │  ├─ Store.swift       the UI's queries over sync.db and ui.db
│  │  ├─ SettingsView.swift  host, port, the pasted key and the notifications switch
│  │  ├─ ChatListView.swift  the chats
│  │  ├─ ChatView.swift    one chat and its composer
│  │  ├─ Composer.swift    saved draft text and sending without losing a failed draft
│  │  ├─ NewConversationView.swift  topic names, participant selection and public-key entry
│  │  ├─ ProfileView.swift  a person's public key and local name editor
│  │  └─ ChatDetailsView.swift  a group's participants, linked to their profiles
│  └─ Lib/                 one thin layer each over a library nothing else touches
│     ├─ SSH.swift         one command over swift-nio-ssh: key authentication, pinned host key, output
│     └─ SQLite.swift      open, execute, run, query over the C API
├─ core/
│  ├─ go.mod, go.sum
│  └─ core.go              key parsing, decrypt and encrypt with age, sign and verify with SSH signatures
└─ Assets.xcassets/        app icon
```
