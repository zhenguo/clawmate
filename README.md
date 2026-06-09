# ClawMate

A modern iOS SSH/Mosh terminal client built with Flutter, designed for remote development workflows — including pairing with Claude Code on a remote server.

> Connect to your servers from anywhere, with low-latency Mosh, LAN auto-discovery, voice input, and home screen widgets that surface terminal state at a glance.

---

## Features

### Connectivity
- **SSH** — full-featured SSH client powered by `dartssh2` (password & key auth, port forwarding-ready architecture)
- **Mosh** — native C++ Mosh implementation with UDP transport, predictive local echo, and roaming across networks
- **LAN auto-discovery** — Bonjour/mDNS scanning of `_ssh._tcp` services on the local network with multi-IP probing
- **Tailscale awareness** — detects Tailscale VPN status on launch and offers a one-tap shortcut to open the Tailscale app when offline

### Terminal Experience
- xterm-based renderer with 256-color and true-color support
- Custom virtual keyboard toolbar with Ctrl-modifier, arrow keys, Tab, Esc, and common shortcuts
- Voice-to-text input (Chinese/English) via on-device speech recognition
- Alt-buffer aware scrolling (vim/less/top translate swipe gestures to arrow keys)
- Smart focus management — taps only summon the keyboard via the dedicated input bar, never by accident while scrolling
- Wake lock so the screen stays alive during long-running sessions
- Reconnect dialog with live status when network drops

### iOS Home Screen Widgets (WidgetKit)
- **Quick Connect** — tap a saved server to launch directly into its terminal
- **Terminal Preview** — last lines of your active session in monospace, on the home screen
- **Server Monitor** — CPU and memory gauges, refreshed every 30s while connected
- Cross-process data sharing via Keychain access groups (works with wildcard provisioning profiles — no App Group entitlement required)
- Deep linking via `clawmate://connect/{id}`

### Security
- Passwords stored in iOS Keychain via `flutter_secure_storage`
- Widget data shared through a Keychain access group, never plaintext UserDefaults
- No telemetry, no analytics, no cloud sync — your connection list lives only on your device

---

## Architecture

```
lib/
├── app.dart                       # MaterialApp + Riverpod root
├── main.dart
├── core/
│   ├── ssh/                       # dartssh2 wrapper
│   ├── mosh/                      # FFI bindings to native Mosh
│   ├── transport/                 # Unified TerminalTransport abstraction
│   ├── network/                   # Tailscale checker, network utilities
│   ├── storage/                   # Secure storage helpers
│   └── widgets/                   # WidgetKit bridge (Method Channel + deep links)
└── features/
    ├── connections/               # Connection list, form, LAN discovery
    └── terminal/                  # Terminal view, session provider, toolbar

ios/
├── Runner/                        # Flutter host app
│   ├── SceneDelegate.swift        # Scene-based lifecycle, plugin registration
│   ├── WidgetDataBridge.swift     # Keychain bridge (Flutter ↔ Widget extension)
│   └── Runner.entitlements        # Keychain access group
├── ClawMateWidget/                # WidgetKit extension target
│   ├── ClawMateWidget.swift       # Widget bundle entry
│   ├── QuickConnectWidget.swift
│   ├── TerminalPreviewWidget.swift
│   ├── ServerMonitorWidget.swift
│   └── SharedKeychain.swift
└── MoshBuild/                     # Native Mosh build artifacts
```

The terminal session sits behind a `TerminalTransport` interface, so SSH and Mosh share the same UI layer. The same session pushes preview lines and `top` / `free` stats into the Keychain so the home screen widgets stay current.

---

## Build & Run

### Prerequisites
- Flutter SDK ^3.12.0
- Xcode 15+ with iOS 17 SDK
- An Apple Developer account (for device install)
- CocoaPods

### Setup

```bash
git clone https://github.com/zhenguo/clawmate.git
cd clawmate
flutter pub get
cd ios && pod install && cd ..
```

### Configure signing

Open `ios/Runner.xcworkspace` in Xcode and set your Team on both targets:
- `Runner`
- `ClawMateWidgetExtension`

That's the only manual step. The Keychain access group prefix is discovered at runtime by probing the keychain, so no Team ID is hard-coded in source. The access group **suffix** is `com.clawmate.shared` — if you change it, update both `Runner.entitlements` and `ClawMateWidget.entitlements`, plus the `accessGroupSuffix` constant in `WidgetDataBridge.swift` and `SharedKeychain.swift`.

### Build to a device

```bash
flutter build ios --release --no-pub
xcrun devicectl device install app \
  --device <YOUR_DEVICE_UUID> \
  "build/ios/iphoneos/Runner.app"
```

> Mosh requires the native build artifacts under `ios/MoshBuild/`. They are produced by the included build scripts and linked into the Runner target.

---

## Usage

1. **Add a connection** — tap `+` and fill in host, port, username, and password (or pick from the LAN scan sheet).
2. **Pick a transport** — SSH for compatibility, Mosh for low-latency roaming.
3. **Connect** — tap a row in the list.
4. **Add widgets** — long-press the home screen → tap `+` → search "ClawMate" → choose Quick Connect, Terminal Preview, or Server Monitor.

For Mosh, your server must have `mosh-server` installed (`brew install mosh` / `apt install mosh` / `dnf install mosh`).

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI | Flutter, Riverpod |
| Terminal | xterm.dart |
| SSH | dartssh2 |
| Mosh | Native C++ via `dart:ffi` |
| Discovery | nsd (Bonjour / mDNS) |
| Voice | speech_to_text |
| Storage | flutter_secure_storage (Keychain) |
| Widgets | SwiftUI + WidgetKit |
| IPC | Method Channel + Keychain access groups |

---

## Roadmap

- Adaptive polling and iOS QoS tuning for the Mosh transport
- Zero-copy FFI for terminal frame data
- SSH key-based authentication UI
- Android port
- iCloud Keychain sync for connection profiles (opt-in)

---

## Contributing

PRs and issues welcome. Before opening a PR:

1. Run `flutter analyze` and address all warnings.
2. Test on a physical iOS device — the simulator does not exercise widgets or Mosh fully.
3. Keep iOS native code Swift-only; avoid Objective-C unless interfacing with system APIs.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Acknowledgments

- [Mosh](https://mosh.org/) — the mobile shell that makes roaming SSH tolerable
- [xterm.dart](https://github.com/TerminalStudio/xterm.dart) — Flutter terminal renderer
- [dartssh2](https://github.com/TerminalStudio/dartssh2) — pure-Dart SSH client
- [Tailscale](https://tailscale.com/) — the zero-config VPN this app integrates with
