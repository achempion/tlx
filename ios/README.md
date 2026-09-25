# tlx for iOS

A minimal iOS client, built like the desktop: a sync engine keeps `sync.db` in step with the relay,
and the UI works only with SQLite.

## File structure

```
ios/
├─ project.yml             build definition for XcodeGen; the .xcodeproj is generated, not committed
├─ Info.plist              background refresh identifier, background mode, launch screen
├─ Makefile                builds the Go core and generates the Xcode project
├─ Sources/
│  ├─ TlxApp.swift         app entry, lifecycle, background refresh
│  ├─ Relay.swift          SSH get and put, over swift-nio-ssh
│  ├─ SyncEngine.swift     port of tlxd.py: foreground sends and receives, background only receives
│  ├─ Store.swift          the UI's queries, port of tui.py's Store
│  ├─ Identity.swift       key in the Keychain, relay settings, pinned host key
│  ├─ Notifications.swift  local notifications for new messages
│  └─ Views.swift          chat list, chat, composer, settings
├─ core/
│  ├─ go.mod, go.sum
│  └─ core.go              encrypt, decrypt, sign, verify: age and SSH signatures, built with gomobile
└─ Assets.xcassets/        app icon
```
