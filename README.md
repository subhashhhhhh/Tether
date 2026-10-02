# Tether

<p align="center">
  <img src="https://raw.githubusercontent.com/subhashhhhhh/Tether/main/Tether/Tether/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="128" height="128" alt="Tether App Icon" />
</p>

<p align="center">
  <strong>A modern, native macOS companion for Android built on the KDE Connect protocol.</strong>
</p>

<p align="center">
  <a href="https://github.com/subhashhhhhh/Tether/releases"><img src="https://img.shields.io/github/v/release/subhashhhhhh/Tether?style=flat-square&color=blue" alt="Release" /></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?style=flat-square" alt="Swift" />
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20Observation-purple?style=flat-square" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/License-GPL--2.0-green?style=flat-square" alt="License" />
</p>

---

## Overview

**Tether** brings the power and versatility of the KDE Connect ecosystem to macOS in a fully native, sleek, and high-performance application. Designed from the ground up using SwiftUI, Apple's Observation framework, and native system materials, Tether seamlessly bridges the gap between your Mac and your Android device with **0.0% idle CPU** overhead and zero external dependencies.

Whether you want to push files, mirror notifications with inline replies, sync clipboards, control media, or navigate presentations with a virtual laser pointer, Tether provides an integrated, Apple-native experience.

---

## ✨ Features

### 📱 Interactive Phone Mockup Sidebar
- **Dynamic Lockscreen Clock**: Large, high-legibility clock featuring SF Pro Rounded typography that updates live each second.
- **Connection Status Pill**: Real-time network indicator (Wi-Fi / Cellular) and live device connectivity state.
- **Glass Quick Actions**:
  - 📤 **Send File**: Native file picker for instant file transfers.
  - 📋 **Push Clipboard**: One-click bidirectional clipboard synchronization.
  - 🔔 **Find My Phone**: Remotely ring your lost phone at maximum volume.
  - 🔒 **Lock Screen**: Remotely secure your phone screen.
- **Interactive Device Status & Volume**: Live battery level with charging animations, paired with an interactive volume scrubbing popover with haptic feedback.
- **Now Playing Media Widget**: Dynamically expands when music or podcasts are playing on your phone, featuring track metadata, album glyphs, and playback controls (Previous, Play/Pause, Next).

### 📬 Notification Mirroring & Inline Reply
- Forward Android alerts directly to macOS Notification Center.
- **Inline Replies**: Respond to SMS, WhatsApp, Telegram, or Signal notifications directly from macOS notification banners or the in-app Notifications tab.
- **System Permission Guard**: Proactively detects if macOS notification delivery is disabled in System Settings and displays a quick-action banner to restore permissions.

### ⚡️ Drag-and-Drop File Sharing
- Effortless drag-and-drop landing target: drop files or folders directly into Tether to send them instantly over local Wi-Fi.
- Live progress indicator with transfer speed tracking (MB/s) and completed transfers log.

### 💬 SMS Sync & Conversation Threads
- Synchronize active SMS threads from your phone.
- Native conversation viewer with iMessage-style bubbles and a responsive bottom composer.

### 🖱️ Remote Input & Presentation Tools
- **Wireless Trackpad**: Control cursor movement, tap-to-click, and two-finger scrolling from your phone's touchscreen.
- **Virtual Laser Pointer**: Full-screen transparent overlay rendering a high-visibility laser dot for presentations and slide decks.
- macOS Accessibility integration for smooth, native input synthesis (`CGEvent`).

### 💻 Remote Shell Commands
- Configure custom shell scripts and automation commands on your Mac and trigger them on demand from your phone.

### 🎛️ Segmented Menu Bar Utility (`MenuBarExtra`)
- Discreet menu bar companion with stacked glass cards:
  - App status and one-click window launcher.
  - Device overview with live battery gauge.
  - Mini media player widget.
  - Instant pairing request review (Accept / Reject).

---

## 🔒 Privacy & Security

- **Direct Peer-to-Peer Encryption**: All communication is secured using TLS 1.2 / 1.3 over local network sockets (port 1716 UDP & TCP).
- **No Cloud Services or Relays**: Data never leaves your local Wi-Fi network. No telemetry, no third-party servers, and no tracking.
- **Native Keychain Storage**: Unique RSA-2048 device identity certificates and trust keys are securely stored in the macOS Keychain.

---

## 🛠️ System Requirements

- **Mac**: macOS 14.0 (Sonoma) or newer (Apple Silicon & Intel supported).
- **Phone**: Android device running the official **KDE Connect** app (available on [Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) or [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/)).
- **Network**: Both devices must be connected to the same local Wi-Fi network (or reachable via local subnet / VPN like Tailscale).

---

## 📥 Installation

1. Download the latest **`Tether-1.0.dmg`** from the [GitHub Releases](https://github.com/subhashhhhhh/Tether/releases) page.
2. Open the downloaded `.dmg` file.
3. Drag **Tether.app** into your **Applications** folder.
4. Launch **Tether**.

### Pairing Your Phone
1. Open the **KDE Connect** app on your Android device.
2. Under **Available devices**, find your Mac's name and tap **Request Pairing**.
3. A notification banner and pairing card will appear on your Mac. Click **Accept**.
4. Once paired, your phone and Mac will automatically sync whenever they are on the same network!

---

## 🏗️ Building from Source

Tether is written in 100% Swift and SwiftUI with no CocoaPods or external package dependencies.

### Prerequisites
- Xcode 15.0 or newer
- Command Line Tools (`xcode-select --install`)

### Build Commands
```bash
# Clone the repository
git clone https://github.com/subhashhhhhh/Tether.git
cd Tether

# Build the Release configuration
xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release build

# Run unit tests
xcodebuild test -project Tether.xcodeproj -scheme Tether -destination "platform=macOS"
```

The compiled application bundle will be located at:
`build/Build/Products/Release/Tether.app`

---

## 🏛️ Architecture & Tech Stack

- **UI Framework**: SwiftUI with Apple's `@Observable` observation framework.
- **Design System**: AirSync-inspired glassmorphism, native Apple materials (`.ultraThinMaterial`), continuous corner radii, and SF Symbols.
- **Networking**: Apple `Network.framework` (`NWListener`, `NWConnection`) for asynchronous socket I/O and TLS handshake validation.
- **Concurrency**: Native Swift Concurrency (`async`/`await`, `@MainActor`, `Sendable`).
- **Security**: Apple `Security.framework` for X.509 certificate creation and Keychain integration.

---

## 📄 License

Tether is distributed under the GNU General Public License v2.0 (GPL-2.0), matching the KDE Connect protocol ecosystem. See the LICENSE file for details.

---

<p align="center">
  Crafted with care for macOS. Enjoy a seamless connection between Mac and Android!
</p>
