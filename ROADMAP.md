# Roadmap

What Tether does today, what's being built next, and what isn't possible.

Everything here works with the regular **KDE Connect** app on Android from Google Play or F-Droid. Tether never needs a custom phone app, so features that would need one are listed under [Not possible](#not-possible) rather than promised.

Planned features have no dates. Ideas and bug reports are welcome in [Issues](https://github.com/subhashhhhhh/Tether/issues).

## Available now

As of Tether 1.9.1.

### Connecting
- [x] Finds your phone automatically on the same Wi-Fi, including networks that block broadcasts (through Bonjour), and reconnects within seconds when it rejoins
- [x] Finds your phone over [Tailscale](https://tailscale.com), so it works away from home
- [x] Connect by IP address or Tailscale name
- [x] Pairing with certificate pinning, so only your phone can connect as your phone
- [x] A phone that forgot the Mac (after reinstalling KDE Connect, say) can ask to pair again
- [x] Several phones or tablets at once
- [x] Notices within about 15 seconds when a phone leaves Wi-Fi or goes out of range

### Notifications and calls
- [x] Phone notifications in macOS Notification Center
- [x] Reply to messages (SMS, WhatsApp, Telegram, Signal and others) from the banner
- [x] Dismissing on the Mac dismisses on the phone
- [x] Pictures from notifications, such as a sender's photo, in banners and in Tether's list
- [x] No duplicate WhatsApp alerts while WhatsApp for Mac is running; clicking a WhatsApp notification opens it
- [x] **Copy verification codes.** Sign-in codes in notifications get a Copy Code button in the banner and in Tether, with an option to copy them automatically
- [x] Incoming calls in a floating card with the caller's name and photo and a **Silence** button, which becomes an on-call pill with a timer
- [x] Missed call notifications
- [x] Pauses what's playing on the Mac during a call, and resumes it afterwards

### Messages
- [x] SMS conversations sync to the Mac, with names and photos from your phone's contacts
- [x] Read whole threads, with Load Earlier Messages, and send replies
- [x] Start new conversations in the conversation pane, picking a contact or typing a number
- [x] Choose which SIM sends a text on dual-SIM phones, and name your SIMs

### Files and clipboard
- [x] Send files by dropping them on the window or the menu bar popover
- [x] **Share › Tether** in Finder, Photos, Safari and other apps, with a chooser when several phones are connected
- [x] Several files at once, of any size
- [x] Files from the phone land in Downloads, with progress
- [x] Clipboard sync both ways (text)
- [x] **Your phone as a drive.** While it's connected, the phone is mounted in Finder as a drive named after it, with an eject button. Files are read from the phone as you open them, so videos play right away. Works over Wi-Fi and Tailscale, with an optional ADB mode, and needs no administrator password or system extension. Eject and mount it from the Files tab.

### Media and controls
- [x] See what's playing on the phone, with album art and playback controls
- [x] Set the phone's media volume while something is playing
- [x] **Control the Mac from your phone.** KDE Connect's Multimedia control shows what's playing on the Mac (Music, Spotify, a video in Safari) with artwork, controls it, and sets the Mac's volume
- [x] **Find Phone** rings it at full volume
- [x] **Ring your Mac from your phone** with KDE Connect's Ring button
- [x] Battery level, charging state, network type and signal strength

### Using your phone as an input device
- [x] Trackpad and keyboard for the Mac (KDE Connect's Remote Input)
- [x] Presentation remote with an on-screen laser pointer
- [x] Run commands you set up on the Mac from the phone
- [x] Run your Mac Shortcuts from the phone (optional)

### The app
- [x] Menu bar popover and a main window, with Liquid Glass on macOS 26 and translucent materials on macOS 15
- [x] Light and Dark mode, accent colour, and a Reduce Motion setting
- [x] Lock the Mac when your phone leaves (optional)
- [x] Updates itself, after checking each update's signature
- [x] Homebrew install: `brew install --cask subhashhhhhh/tether/tether`
- [x] Apple Silicon and Intel, macOS 15 Sequoia or later

## Planned

### Coming next
- [ ] **Battery alerts.** "Phone is at 15%" and "Phone fully charged".
- [ ] **Search all your messages**, not just the latest in each thread.
- [ ] **Shortcuts and Siri.** Actions such as "Send file to phone", "Ring my phone", "Send a text" and "Get phone battery" for the Shortcuts app.

### Later
- [ ] **Widgets.** Battery and what's playing on the desktop and in Notification Center.
- [ ] **Search messages in Spotlight.**
- [ ] **Type on your phone from the Mac keyboard**, using KDE Connect's keyboard on the phone.
- [ ] **Phone as a drawing tablet**, with pressure, using KDE Connect's Digitizer.
- [ ] **Every player on the Mac on your phone.** macOS reports one Now Playing app at a time; showing Safari and a second browser side by side needs undocumented per-app functions that may not be reachable.
- [ ] **Keep messages on the Mac** so Messages opens instantly instead of fetching from the phone each launch.

## Not possible

These would need features the KDE Connect Android app doesn't have, or that macOS doesn't allow.

- **Lock the phone from the Mac.** KDE Connect for Android has no remote lock.
- **Unlock the Mac with the phone.** That needs a dedicated phone app; locking when the phone leaves is available.
- **Change ringer or notification volume.** The phone only accepts volume changes for an active media player.
- **Show Mac notifications on the phone.** macOS doesn't let apps read other apps' notifications.
- **Seek in a Safari video from the phone.** Safari ignores seeking from other apps; play, pause and skip work.
- **Answer or decline calls from the Mac.** KDE Connect for Android can only silence the ringer, and call audio would stay on the phone anyway.
- **Android app icons in notifications.** The phone sends a notification's picture but not the app's icon, and macOS always shows Tether's icon in the corner of a banner. Fetching icons online is off the table, since Tether doesn't use the internet.
- **Send the phone's clipboard automatically.** Since Android 10, apps in the background can't read the clipboard, so KDE Connect only sends it when you tap its "Send clipboard" button or tile. The Mac's clipboard still reaches the phone automatically.
- **Clipboard images and files.** KDE Connect's clipboard sync is text only. Use Share or drag and drop instead.
