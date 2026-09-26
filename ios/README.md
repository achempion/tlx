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

Run the local-name persistence and shared-name update tests with:

```bash
xcodebuild -project tlx.xcodeproj -scheme tlx -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## File structure

```
ios/
├─ project.yml             build definition for XcodeGen; the .xcodeproj is generated, not committed
├─ Info.plist              bundle keys and the launch screen; background refresh comes with that milestone
├─ Makefile                make core binds the Go core, make project generates the Xcode project
├─ Sources/
│  ├─ TlxApp.swift         entry point: Settings, the switch between screens, the engine's lifetime
│  ├─ Identity.swift       the private key, parsed by the core and kept in the Keychain
│  ├─ Sync/                the tlxd port
│  │  ├─ Relay.swift       the relay address, and get and put in tlx terms
│  │  ├─ Storage.swift     sync.db: tlxd's schema, saving messages, the outbox queries
│  │  └─ SyncEngine.swift  decrypt and verify, sign and encrypt, the receive and send loops
│  ├─ Views/               the tui port
│  │  ├─ Store.swift       the UI's queries over sync.db and ui.db
│  │  ├─ SettingsView.swift  host, port and the pasted key
│  │  ├─ ChatListView.swift  the chats
│  │  ├─ ChatView.swift    one chat and its composer
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
