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

    var body: some View {
        ScrollView {
            details
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
        }
    }

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
                    Button("Find Phone", systemImage: "speaker.wave.3") { device.findMyPhone() }
                        .help("Ring \(device.name) at full volume")
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

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            if device.hasNowPlaying {
                NowPlayingPanel(device: device)
            }

            if !device.notifications.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader("Notifications") {
                        if device.notifications.count > 3 {
                            Button("Show All") { onSelectSection(.notifications) }
                                .buttonStyle(.link)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(device.notifications.prefix(3).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 16) }
                            NotificationPreviewRow(item: item)
                        }
                    }
                    .contentCard()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                PanelHeader("Files") {
                    if device.transfers.count > 3 {
                        Button("Show All") { onSelectSection(.files) }
                            .buttonStyle(.link)
                    }
                }
                VStack(spacing: 0) {
                    // Sending lives with the transfers it produces.
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text("Drop files anywhere in this window to send them to \(device.name).")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Choose Files…") {
                            device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    ForEach(device.transfers.prefix(3)) { item in
                        Divider().padding(.leading, 16)
                        TransferRow(item: item)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
                .contentCard()

                Text("Files from \(device.name) are saved in Downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            RemoteInputRow()
        }
    }
}

// MARK: - Clipboard

/// Sends this Mac's clipboard with a click. The arrow lists what the device
/// sent lately, to put back on the clipboard.
private struct ClipboardMenu: View {
    let device: DeviceViewModel

    var body: some View {
        Menu {
            Section("Sent by \(device.name)") {
                if device.receivedClipboard.isEmpty {
                    // Android only lets an app read the clipboard when asked to.
                    Text("Nothing yet. Tap Send Clipboard in KDE Connect on \(device.name).")
                } else {
                    ForEach(Array(device.receivedClipboard.enumerated()), id: \.offset) { _, text in
                        Button(Self.preview(of: text), systemImage: "doc.on.doc") {
                            device.copyReceivedClipboard(text)
                        }
                    }
                }
            }
        } label: {
            Label("Send Clipboard", systemImage: "doc.on.clipboard")
        } primaryAction: {
            device.sendClipboard()
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Send this Mac's clipboard to \(device.name). The arrow lists what \(device.name) sent.")
    }

    static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
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
            if !item.text.isEmpty {
                // The message is the content, so it's not greyed out.
                Text(item.text)
                    .lineLimit(2)
            }
            if let code = item.code {
                CopyCodeButton(code: code)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
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
    @Environment(\.controlActiveState) private var controlActiveState

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
        .onChange(of: controlActiveState) {
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
