<p align="center">
  <img src="Tether/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="112" height="112" alt="Tether app icon" />
</p>

<h1 align="center">Tether</h1>

<p align="center">
  <strong>Use your Android phone with your Mac.</strong><br />
  Notifications, texts, calls, files and the clipboard, in a native Mac app of less than 3&nbsp;MB.
</p>

<p align="center">
  <a href="https://github.com/subhashhhhhh/Tether/releases/latest"><img src="https://img.shields.io/github/v/release/subhashhhhhh/Tether?style=flat-square&color=2e6bf0&label=download" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15 or later" />
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-supported-black?style=flat-square" alt="Apple Silicon and Intel" />
  <img src="https://img.shields.io/badge/license-GPL--2.0-3b8f4a?style=flat-square" alt="GPL-2.0" />
</p>

<p align="center">
  <img src="docs/images/hero.jpg" alt="Tether's main window and menu bar popover on a Mac desktop" />
</p>

Tether is a native macOS app for **KDE Connect**, a free app for Android. You pair your phone one time. After that, your phone shows in the menu bar when it is near your Mac.

Your phone notifications show on the Mac, and you can reply to them. Your text messages and calls show on the Mac. Files and the clipboard go in the two directions. You can ring, lock or control your phone from the Mac.

Tether uses only Swift and SwiftUI. It does not use Qt, Electron or third-party libraries.

## Download

We recommend [Homebrew](https://brew.sh). Homebrew also prevents the "can't be opened" warning (see below).

```bash
brew install --cask subhashhhhhh/tether/tether
```

You can also download Tether from the **[Releases page](https://github.com/subhashhhhhh/Tether/releases/latest)**. There are two disk images. Use the disk image for your Mac:

| Your Mac | Download |
| --- | --- |
| Apple Silicon (M1 and later) | `Tether-<version>-AppleSilicon.dmg` |
| Intel | `Tether-<version>-Intel.dmg` |

To find the type of your Mac, open the Apple menu and select **About This Mac**. An Apple Silicon Mac shows **Chip**. An Intel Mac shows **Processor**. Tether needs **macOS 15 Sequoia** or later.

Tether updates itself. It looks for a new version one time each day. You can also select **Tether › Check for Updates…**.

On your phone, install **KDE Connect** from [Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) or [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/).

## What Tether does

**Notifications.** Your phone notifications show in Notification Center on the Mac. You can reply to messages from the banner, for example SMS, WhatsApp, Telegram and Signal. When you remove a notification on the Mac, Tether also removes it on the phone. A notification with a sign-in code gets a **Copy Code** button. Tether can also copy the code automatically.

**Pictures in notifications.** When the phone sends a picture with a notification, Tether shows it. This picture is usually the photo of the sender. If an app does not send a picture, Tether shows the small icon of the app. The banner always shows the Tether icon in its corner, because macOS does not let apps change it. See [notification images](docs/notification-images.md).

**WhatsApp.** If WhatsApp for Mac is open, Tether does not show a second alert for each WhatsApp message. The messages stay in the Tether notification list. When you click a WhatsApp notification, WhatsApp for Mac opens.

**Text messages.** Your SMS conversations show in the Messages tab, with names and photos from the contacts on your phone. You can read full conversations and reply. To start a new conversation, click the compose button or press ⌘N. Then type a name or a number in the **To** field. If your phone has two SIM cards, select the SIM in the menu next to the send button. You can give each SIM a name, for example the name of its carrier.

**Calls.** When your phone rings, a card shows at the top right of the screen. The card shows the name and photo of the caller. Click **Silence** to stop the ringer on the phone. When you answer on the phone, the card becomes a small bar with a call timer. Music and video on the Mac pause during the call and start again after the call. You cannot answer or decline calls on the Mac, because KDE Connect does not support this.

**Files.** To send files to your phone, drop them on the Tether window or on the menu bar popover. You can also select **Share › Tether** in Finder, Photos and other apps. If more than one phone is connected, Tether asks which phone to use. Files from your phone go into your **Downloads** folder.

**Your phone as a drive.** When your phone is connected, it shows in Finder as a drive with the name of the phone. You can open, copy and move files on the phone. Tether reads each file only when you open it, so a video starts immediately. The drive uses the file sharing of KDE Connect. It works on Wi-Fi and on Tailscale, and it does not need an administrator password. If you use ADB, you can select wireless debugging in **Settings › Files**.

**Clipboard and media.** When you copy text on one device, you can paste it on the other device. Tether shows the music or video that plays on your phone, with its artwork. You can control it and change its volume from the Mac. This also works in the opposite direction. The Multimedia control of KDE Connect on the phone shows the music or video that plays on the Mac, with its artwork. It also changes the volume of the Mac.

**Battery.** Tether shows the battery level of your phone. KDE Connect on your phone also shows the battery level of your MacBook.

**Find your devices.** **Find Phone** rings your phone at full volume. **Ring** in KDE Connect on the phone rings your Mac.

**Your phone as a trackpad and presenter.** The Remote Input and Presentation tools of KDE Connect move the pointer, click, scroll and type on the Mac. They also show a laser pointer on the screen. These tools need Accessibility access. You can give this access from the Overview or from Settings in Tether.

**Commands.** You can set up shell commands and Shortcuts on your Mac, and then start them from your phone. Tether can also lock the Mac when your phone goes away.

**Menu bar and main window.** The menu bar popover shows the battery and the connection of your phone. It also shows quick actions, the music that plays, and new pairing requests. The main window shows your devices in the sidebar. Each phone has five tabs: Overview, Messages, Notifications, Files and Commands. On macOS 26, Tether uses Liquid Glass. On macOS 15, it uses translucent materials.

<p align="center">
  <img src="docs/images/messages.jpg" alt="Tether's Messages view with a reply from a notification banner" />
</p>

See the **[Roadmap](ROADMAP.md)** for new features that we plan, and for features that KDE Connect cannot support.

## Connection

Tether finds your phone automatically when the phone and the Mac are on the same Wi-Fi network. Some office and school networks block the usual KDE Connect messages. On these networks, Tether finds your phone with Bonjour. When your phone leaves the Wi-Fi network and comes back, Tether connects to it again in a few seconds.

The first time, macOS can ask if Tether can find devices on your local network. Click **Allow**.

If Tether does not find your phone, use **Connect by Address…** with the IP address of the phone.

## Use Tether from anywhere with Tailscale

KDE Connect usually needs your phone and your Mac on the same Wi-Fi network. If you use [Tailscale](https://tailscale.com) on the two devices, Tether finds your phone on your tailnet. Then Tether also works on mobile data or on a different network.

- Tether connects only to Android and iOS devices that use **your** Tailscale account. Tether does not connect to devices that other people share with you.
- Tether gets your tailnet from the `tailscale` app on your Mac. Tether does not connect to the servers of Tailscale.
- To turn this feature on or off, go to **Settings › General › Tailscale**. **Connect by Address…** also accepts Tailscale names, for example `phone.tailnet.ts.net`.

<p align="center">
  <img src="docs/images/anywhere.jpg" alt="Tether connecting to a phone on mobile data over Tailscale" />
</p>

## Small and quiet

<p align="center">
  <img src="docs/images/size.jpg" alt="Tether's download compared with the official KDE Connect for macOS at 87 MB" />
</p>

| | Tether 1.8 | KDE Connect 26.08 for macOS |
| --- | --- | --- |
| Download (Apple Silicon disk image) | **2.6 MB** | 87 MB |
| Installed app | **4.3 MB** | about 370 MB |
| Memory when idle | **23 MB** | 150 to 300 MB |
| CPU when idle | **0%** | 1 to 5% |

We measured these values in October 2026 on an Apple Silicon Mac. For Tether, we used the 1.8 release in the background, connected to a phone, with its contacts and messages synchronized. The download size of KDE Connect comes from the KDE release builds. When the Tether window is open, Tether uses more memory: approximately 50 to 80 MB with long conversations.

## Privacy and security

- **No cloud.** Your phone and your Mac connect directly on your local network or on your Tailscale network. Tether has no servers, accounts, analytics or telemetry. Tether does not connect to the internet, except to look for updates.
- **Encryption.** All connections and file transfers use TLS.
- **Pinned to your phone.** When you pair, Tether keeps the certificate of your phone. All subsequent connections must use that certificate. Tether refuses a device that only pretends to be your phone. Tether accepts a pairing request only for the device that it shows to you.
- **Signed updates.** All releases have the same signature. Tether installs an update only if the update has the same signature as Tether. See [docs/signing.md](docs/signing.md).
- **Private identity.** The certificate and key of Tether are in `~/Library/Application Support/Tether`. Only your user account can read them. Tether loads them into memory, not into the keychain.

## Install and pair

1. Install Tether with Homebrew. Or open the disk image and move **Tether** into **Applications**.
2. Open Tether. Tether shows in the menu bar.
3. On your phone, open **KDE Connect** and select your Mac in the device list.
4. On the Mac, click **Pair**.

You can also start the pairing on the Mac. Your phone shows under **Nearby** in the sidebar of Tether. If your phone does not show, use **Connect by Address…** with its IP address or Tailscale name.

The first time Tether shows your phone as a drive, KDE Connect on the phone can ask for access to files. Give this access.

### "Tether can't be opened"

Apple did not notarize Tether, because notarization needs a paid developer account. Thus macOS blocks a downloaded copy of Tether the first time. This does not occur when you install with Homebrew. To open Tether:

1. Open Tether, then close the warning.
2. Open **System Settings → Privacy & Security**.
3. Go to **Security** and click **Open Anyway**.

You can also use this command in Terminal:

```bash
xattr -cr /Applications/Tether.app
```

## Build from source

You need **Xcode 26** or later, because the project uses the default main-actor isolation of Swift 6.2. The project has no package dependencies.

```bash
git clone https://github.com/subhashhhhhh/Tether.git
cd Tether

# Run the tests
xcodebuild test -project Tether.xcodeproj -scheme Tether -destination "platform=macOS"

# Build the app (the result is in build/Build/Products/Release/Tether.app)
xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -derivedDataPath build build

# Build the two release disk images (Apple Silicon and Intel) into dist/
scripts/release.sh
```

`release.sh` signs Tether with the "Tether Self-Signed" certificate of the maintainer. See [docs/signing.md](docs/signing.md) for the reason. This document also tells you how to test the updater with `scripts/test-updater.sh`.

### How Tether works

- **User interface:** SwiftUI with `@Observable` view models and standard controls. Tether uses Liquid Glass on macOS 26 and materials on macOS 15. It follows Light and Dark mode, your accent color and the accessibility settings.
- **Phone drive:** a small NFS version 3 server on the loopback interface. The user mounts it with `mount_nfs`, and a local Bonjour host gives it its name. The data comes from SFTP (a native SSH client on CryptoKit) or from ADB.
- **Network:** BSD sockets with `poll()` and TLS from the Security framework. KDE Connect changes an open plaintext connection into a TLS connection. `Network.framework` cannot do this. Tether also finds phones with Bonjour (`_kdeconnect._udp`), as KDE Connect does.
- **Identity:** Tether makes its certificate one time with the `openssl` tool of macOS. Then the Security framework loads it into memory.
- **Now Playing on the Mac:** since macOS 15.4, only programs that Apple signs can read Now Playing. Thus Tether runs [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) through `/usr/bin/perl`. `scripts/build-mediaremote-adapter.sh` builds it from source, and the result is in `Vendor/`.

## License

Tether uses the GPL-2.0 license, as KDE Connect does. See [LICENSE](LICENSE). Tether includes mediaremote-adapter by Jonas van den Berg, with the BSD 3-Clause License ([Vendor/MediaRemoteAdapter/LICENSE](Vendor/MediaRemoteAdapter/LICENSE)).

Tether is an independent project. It is not part of KDE.
