//
//  PhoneMockupView.swift
//  Tether
//
//  AirSync-inspired interactive phone widget for the sidebar, featuring a live clock,
//  connection status pill, glass quick-actions, mini media player, and battery/volume status.
//

import SwiftUI
import AppKit

public struct PhoneMockupView: View {
    @Bindable var device: DeviceViewModel

    @State private var showingVolumePopover: Bool = false
    @State private var tempVolume: Double = 0.5
    @State private var isDraggingVolume: Bool = false

    private let cardWidth: CGFloat = 220
    private let cardHeight: CGFloat = 460
    private let cornerRadius: CGFloat = 24

    public init(device: DeviceViewModel) {
        self.device = device
    }

    public var body: some View {
        ZStack {
            // Wallpaper background
            phoneWallpaper

            // Foreground controls
            VStack(spacing: 12) {
                // Top Island: Connection status pill
                ConnectionStatusPill(
                    status: device.status,
                    networkType: device.networkType
                )
                .padding(.top, 14)

                // Device Name
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                // Center: Dynamic live clock
                LiquidClockView(isCompact: hasActiveMedia)
                    .padding(.vertical, hasActiveMedia ? 2 : 12)

                // Quick Action Buttons Row
                glassActionButtonsRow
                    .padding(.horizontal, 8)

                Spacer()

                // Bottom: Now Playing card (if active)
                if hasActiveMedia {
                    miniMediaPlayerCard
                        .transition(.scale.combined(with: .opacity))
                }

                // Bottom Bar: Battery & Volume Status
                bottomStatusBar
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasActiveMedia)
        .onAppear {
            tempVolume = Double(device.volume)
        }
        .onChange(of: device.volume) { _, newVol in
            if !isDraggingVolume {
                tempVolume = Double(newVol)
            }
        }
    }

    private var hasActiveMedia: Bool {
        if let title = device.nowPlayingTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    // MARK: - Phone Wallpaper Background
    private var phoneWallpaper: some View {
        ZStack {
            // Base dark elegant gradient
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.22),
                    Color(red: 0.05, green: 0.06, blue: 0.12),
                    Color(red: 0.02, green: 0.03, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Ambient radial light sheen
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.20),
                    Color.purple.opacity(0.12),
                    Color.clear
                ],
                center: .top,
                startRadius: 20,
                endRadius: 240
            )

            // Subtle glass noise overlay
            Color.black.opacity(0.15)
        }
    }

    // MARK: - Glass Action Buttons
    private var glassActionButtonsRow: some View {
        HStack(spacing: 8) {
            // Send File
            GlassButtonView(
                systemImage: "square.and.arrow.up",
                circleSize: 34,
                fixedIconSize: 15,
                helpText: "Send File to Phone"
            ) {
                openSendFileDialog()
            }

            // Send Clipboard
            GlassButtonView(
                systemImage: "doc.on.clipboard",
                circleSize: 34,
                fixedIconSize: 15,
                helpText: "Push Clipboard to Phone"
            ) {
                device.sendClipboard()
            }

            // Ring Phone
            GlassButtonView(
                systemImage: "speaker.wave.3.fill",
                circleSize: 34,
                fixedIconSize: 14,
                helpText: "Find My Phone (Ring)"
            ) {
                device.findMyPhone()
            }

            // Lock Phone
            GlassButtonView(
                systemImage: "lock.fill",
                circleSize: 34,
                fixedIconSize: 14,
                helpText: "Lock Phone Screen"
            ) {
                device.lockDevice()
            }
        }
    }

    // MARK: - Mini Media Player Card
    private var miniMediaPlayerCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: 26, height: 26)
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.nowPlayingTitle ?? "Music")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let artist = device.nowPlayingArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            // Media control buttons
            HStack(spacing: 12) {
                Button {
                    device.previousMedia()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button {
                    device.playPauseMedia()
                } label: {
                    Image(systemName: device.nowPlayingIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button {
                    device.nextMedia()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Bottom Status Bar (Battery & Volume)
    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            // Battery Indicator
            HStack(spacing: 4) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 12))
                    .foregroundColor(batteryColor)

                if let batt = device.batteryPercent {
                    Text("\(batt)%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            Spacer()

            // Volume Control Popover Button
            Button {
                showingVolumePopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                    Text("\(Int(device.volume * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingVolumePopover, arrowEdge: .top) {
                volumePopoverView
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Volume Popover View
    private var volumePopoverView: some View {
        VStack(spacing: 8) {
            Text("Phone Media Volume")
                .font(.caption.weight(.semibold))

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)

                Slider(value: $tempVolume, in: 0...1, onEditingChanged: { editing in
                    isDraggingVolume = editing
                    if !editing {
                        device.setVolume(Float(tempVolume))
                    }
                })
                .frame(width: 140)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
            }

            Text("\(Int(tempVolume * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 210)
    }

    private var batteryIcon: String {
        if device.isCharging {
            return "battery.100bolt"
        }
        guard let level = device.batteryPercent else { return "battery.100" }
        switch level {
        case 0...15: return "battery.0"
        case 16...35: return "battery.25"
        case 36...60: return "battery.50"
        case 61...85: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryColor: Color {
        if device.isCharging {
            return .green
        }
        guard let level = device.batteryPercent else { return .white }
        if level <= 20 {
            return .red
        }
        return .white.opacity(0.85)
    }

    private var volumeIcon: String {
        if device.isMuted || device.volume == 0 {
            return "speaker.slash.fill"
        } else if device.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if device.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func openSendFileDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        if panel.runModal() == .OK {
            for url in panel.urls {
                device.sendFile(url: url)
            }
        }
    }
}
