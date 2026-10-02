//
//  CommandsView.swift
//  Tether
//
//  UI for managing and executing predefined shell commands triggered from phone or Mac.
//

import SwiftUI

public struct CommandsView: View {
    @ObservedObject var runCommandPlugin = TetherService.shared.runCommandPlugin
    @ObservedObject var service = TetherService.shared
    @State private var showingAddSheet = false
    @State private var newCommandName = ""
    @State private var newCommandString = ""
    @State private var selectedCommandId: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Command List
            List(runCommandPlugin.commands, selection: $selectedCommandId) { command in
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(command.name)
                            .font(.system(size: 13, weight: .medium))

                        Text(command.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: {
                        runCommand(command)
                    }) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive, action: {
                        deleteCommand(command)
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)

            Divider()

            // Console Output Drawer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CONSOLE OUTPUT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    Spacer()

                    if let selectedId = selectedCommandId, let logs = runCommandPlugin.commandLogs[selectedId], !logs.isEmpty {
                        Text("\(logs.count) lines")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let logs = activeLogs
                        if logs.isEmpty {
                            Text("No command output yet. Select a command and click Run.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(lineColor(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .cornerRadius(6)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationTitle("Commands")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    showingAddSheet = true
                }) {
                    Label("Add Command", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            addCommandSheet
        }
    }

    private var activeLogs: [String] {
        if let id = selectedCommandId, let logs = runCommandPlugin.commandLogs[id] {
            return logs
        }
        // If none selected, return the most recent command's logs
        if let first = runCommandPlugin.commands.first, let logs = runCommandPlugin.commandLogs[first.id] {
            return logs
        }
        return []
    }

    private func lineColor(for line: String) -> Color {
        if line.starts(with: "▶") {
            return .accentColor
        } else if line.starts(with: "stderr:") {
            return .red
        } else if line.starts(with: "■") {
            return .green
        }
        return .primary
    }

    private func runCommand(_ command: RemoteCommand) {
        selectedCommandId = command.id
        let activeConn = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired })?.value
        runCommandPlugin.startCommand(key: command.id, connection: activeConn)
    }

    private func deleteCommand(_ command: RemoteCommand) {
        let activeConn = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired })?.value
        runCommandPlugin.removeCommand(id: command.id, connection: activeConn)
    }

    private var addCommandSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Remote Command")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. Sleep Display", text: $newCommandName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shell Command")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. pmset displaysleepnow", text: $newCommandString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    showingAddSheet = false
                    newCommandName = ""
                    newCommandString = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let cmd = RemoteCommand(name: newCommandName, command: newCommandString)
                    let activeConn = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired })?.value
                    runCommandPlugin.addCommand(cmd, connection: activeConn)

                    showingAddSheet = false
                    newCommandName = ""
                    newCommandString = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCommandName.isEmpty || newCommandString.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 400)
    }
}
