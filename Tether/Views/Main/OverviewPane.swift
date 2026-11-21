//
//  OverviewPane.swift
//  Tether
//
//  A connected device's home: who it is and how it's doing, the things you do
//  to it, then what it's playing, what it has told you lately, and the files
//  that went back and forth.
//

import SwiftUI

struct OverviewPane: View {
    @Bindable var device: DeviceViewModel
    let onSelectSection: (DeviceSection) -> Void
    /// Set for a while after asking the phone to ring. The phone can't be
    /// told to stop, and doesn't say when it has; someone taps it.
    @State private var isRinging = false

    var body: some View {
        // A list, so the notifications here swipe away as they do on their
        // own page. Everything else is a plain row with no separator.
        List {
            header
                .overviewRow(top: 20)

            if device.hasNowPlaying {
                NowPlayingPanel(device: device)
                    .overviewRow()
            }

            if !device.notifications.isEmpty {
                PanelHeader("Notifications") {
                    Button("Show All") { onSelectSection(.notifications) }
                        .buttonStyle(.link)
                }
                .overviewRow(bottom: 2)

                let latest = Array(device.notifications.prefix(3))
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, item in
                    // No insets: the inset list style keeps the row in from the
                    // sides, so the row is exactly the card and a swipe
                    // uncovers Dismiss right at the card's edge.
                    NotificationPreviewRow(item: item, device: device)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        // Part of the row, not its background, so a swipe
                        // moves the whole card.
                        .background(GroupCardBackground(isFirst: index == 0, isLast: index == latest.count - 1,
                                                        maxWidth: .infinity, margin: 0))
                        .listRowBackground(Color.clear)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if item.isDismissable {
                                Button("Dismiss", systemImage: "xmark", role: .destructive) { device.dismiss(item) }
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                PanelHeader("Files") {
                    if device.transfers.count > 3 {
                        Button("Show All") { onSelectSection(.files) }
                            .buttonStyle(.link)
                    }
                }
                TransfersCard(device: device, limit: 3)

                Text("Files from \(device.name) are saved in Downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .overviewRow(top: 18)

            RemoteInputRow()
                .overviewRow()
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .noTopScrollEdge()
        .readableCardList()
    }

    /// Rows' own side inset, on top of the list's. None, so every card on
    /// the page has the same edges as the notification cards.
    fileprivate static let margin: CGFloat = 0

    // MARK: Header and actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: device.deviceType.systemImageName)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(2)
                    HStack(spacing: 14) {
                        StatusPill(
                            text: device.isViaTailscale ? "Tailscale" : "Wi-Fi",
                            systemImage: device.isViaTailscale ? "point.3.connected.trianglepath.dotted" : "wifi"
                        )
                        if let battery = device.batteryPercent {
                            StatusPill(text: "\(battery)%", systemImage: DeviceSymbols.battery(battery, charging: device.isCharging),
                                       tint: battery < 20 && !device.isCharging ? .red : (device.isCharging ? .green : .secondary))
                        }
                        if let network = device.networkType, !network.isEmpty {
                            StatusPill(text: network, systemImage: "cellularbars", tint: .secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button(isRinging ? "Ringing…" : "Find Phone", systemImage: "speaker.wave.3") {
                        device.findMyPhone()
                        isRinging = true
                    }
                    .symbolEffect(.variableColor.iterative, isActive: isRinging)
                    .disabled(isRinging)
                    .help(isRinging ? "\(device.name) rings until someone taps it" : "Ring \(device.name) at full volume")
                    .task(id: isRinging) {
                        guard isRinging else { return }
                        try? await Task.sleep(for: .seconds(10))
                        isRinging = false
                    }
                    ClipboardMenu(device: device)
                    if device.canLock {
                        Button("Lock", systemImage: "lock") { device.lockDevice() }
                            .help("Lock \(device.name)")
                    }
                }
                .glassButton()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

}

private extension View {
    /// A row of the overview's list that isn't a notification: kept to the
    /// page's column, with no separator and nothing behind it.
    func overviewRow(top: CGFloat = 12, bottom: CGFloat = 12) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: top, leading: OverviewPane.margin, bottom: bottom, trailing: OverviewPane.margin))

            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Clipboard

/// Sends this Mac's clipboard with a click. The arrow lists what the device
/// sent lately, to put back on the clipboard.
private struct ClipboardMenu: View {
    let device: DeviceViewModel
    @State private var isShowingReceived = false

    var body: some View {
        // Two real glass buttons rather than one split menu button: a split
        // menu draws its own bezel and ignores the glass button style.
        Button("Send Clipboard", systemImage: "doc.on.clipboard") {
            device.sendClipboard()
        }
        .help("Send this Mac's clipboard to \(device.name)")

        // A glass button with a popover, not a menu: a menu in content
        // draws its own bezel and doesn't take the glass style.
        Button {
            isShowingReceived.toggle()
        } label: {
            Label("Clipboard from \(device.name)", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
                // Square, and as tall as the text buttons' labels, so the
                // circle is as tall as they are.
                .frame(width: 16, height: 16)
        }
        .buttonBorderShape(.circle)
        .popover(isPresented: $isShowingReceived, arrowEdge: .bottom) {
            ReceivedClipboardList(device: device) { isShowingReceived = false }
        }
        .help("What \(device.name) sent to this Mac's clipboard")
    }

    static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }
}

/// What the device last put on this Mac's clipboard; a click copies one again.
private struct ReceivedClipboardList: View {
    let device: DeviceViewModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sent by \(device.name)")
                .font(.headline)
            if device.receivedClipboard.isEmpty {
                // Android only lets an app read the clipboard when asked to.
                Text("Nothing yet. Tap Send Clipboard in KDE Connect on \(device.name).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(device.receivedClipboard.enumerated()), id: \.offset) { _, text in
                    Button {
                        device.copyReceivedClipboard(text)
                        close()
                    } label: {
                        Label(ClipboardMenu.preview(of: text), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Copy to this Mac's clipboard")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - Now playing

private struct NowPlayingPanel: View {
    @Bindable var device: DeviceViewModel
    @State private var draftVolume: Float = 0.5
    @State private var isEditingVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("Now Playing")
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.nowPlayingTitle ?? "")
                            .font(.headline)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 18) {
                        Button("Previous", systemImage: "backward.fill") { device.previousMedia() }
                        Button(device.nowPlayingIsPlaying ? "Pause" : "Play",
                               systemImage: device.nowPlayingIsPlaying ? "pause.fill" : "play.fill") {
                            device.playPauseMedia()
                        }
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        Button("Next", systemImage: "forward.fill") { device.nextMedia() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                }

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $draftVolume, in: 0...1) { Text("Volume") } onEditingChanged: { editing in
                        isEditingVolume = editing
                        // Send once when the drag ends rather than on every tick.
                        if !editing { device.setVolume(draftVolume) }
                    }
                    .labelsHidden()
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!device.canSetVolume)
                .help(device.canSetVolume ? "Media volume on \(device.name)" : "Start playing something on \(device.name) to change its volume")
            }
            .padding(16)
            .contentCard()
        }
        .onAppear { draftVolume = device.volume }
        .onChange(of: device.volume) {
            if !isEditingVolume { draftVolume = device.volume }
        }
    }

    private var subtitle: String? {
        let parts = [device.nowPlayingArtist, device.nowPlayingAlbum].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = device.albumArt {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Notifications

private struct NotificationPreviewRow: View {
    let item: PhoneNotification
    let device: DeviceViewModel

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                NotificationAppIcon(appName: item.appName,
                                    glyph: item.isFromSystem && item.imageIsGlyph ? item.imageData : device.glyph(for: item),
                                    size: 18)
                Text(item.appName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .fontWeight(.semibold)
                .lineLimit(1)
            if item.isRedacted {
                RedactedText()
            } else if !item.conversation.isEmpty {
                ConversationText(notification: item)
                    .lineLimit(2)
            } else if !item.text.isEmpty {
                // The message is the content, so it's not greyed out. Its line
                // breaks are spaces here: a two-line preview of text that
                // breaks early would stop halfway across the card.
                Text(Self.oneLine(item.text))
                    .lineLimit(2)
            }
            NotificationQuickActions(notification: item, device: device)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Remote input

/// Shown only while Accessibility access is missing; once granted there's nothing to say.
private struct RemoteInputRow: View {
    @State private var isTrusted = InputSynthesizer.shared.isAccessibilityTrusted
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            if !isTrusted {
                HStack(spacing: 14) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use your phone as a trackpad")
                            .fontWeight(.semibold)
                        Text("Tether needs Accessibility access to move the pointer and type for your phone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Allow…") { InputSynthesizer.shared.openAccessibilitySettings() }
                }
                .padding(16)
                .contentCard()
            }
        }
        // Re-check when the window regains focus, e.g. after visiting System Settings.
        .onChange(of: appearsActive) {
            isTrusted = InputSynthesizer.shared.isAccessibilityTrusted
        }
    }
}

#if DEBUG
#Preview {
    OverviewPane(device: .mockConnectedPhone()) { _ in }
        .frame(width: 900, height: 760)
}
#endif
