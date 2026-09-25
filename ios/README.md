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

## File structure

```
ios/
├─ project.yml             build definition for XcodeGen; the .xcodeproj is generated, not committed
├─ Info.plist              bundle keys and the launch screen; background refresh comes with that milestone
├─ Makefile                make core binds the Go core, make project generates the Xcode project
├─ Sources/
│  ├─ TlxApp.swift         entry point: Settings, and the switch between the settings screen and the chats
│  ├─ Identity.swift       the private key, parsed by the core and kept in the Keychain
│  ├─ Relay.swift          the relay address, and get and put in tlx terms
│  ├─ SSH.swift            one command over swift-nio-ssh: key authentication, pinned host key, output
│  ├─ SyncEngine.swift     port of tlxd.py: foreground sends and receives, background only receives
│  ├─ Store.swift          the UI's queries, port of tui.py's Store
│  ├─ Notifications.swift  local notifications for new messages
│  ├─ SettingsView.swift   host, port and the pasted key
│  ├─ ChatListView.swift   the chats
│  └─ ChatView.swift       one chat and its composer
├─ core/
│  ├─ go.mod, go.sum
│  └─ core.go              key parsing, then encrypt, decrypt, sign and verify with age and SSH signatures
└─ Assets.xcassets/        app icon
```
