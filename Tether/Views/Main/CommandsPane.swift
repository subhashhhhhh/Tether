//
//  CommandsPane.swift
//  Tether
//
//  Shell commands the paired phone may run on this Mac.
//

import SwiftUI

struct CommandsPane: View {
    let device: DeviceViewModel
    @State private var editing: RemoteCommand?
    @State private var commandToDelete: RemoteCommand?
    @AppStorage(RunCommandPlugin.shortcutsKey) private var shareShortcuts = false

    var body: some View {
        GlassPage {
            GlassSection("On this Mac", footer: "\(device.name) can run these from Run Command in KDE Connect. They run as your user account, so only add ones you trust.") {
                if device.commands.isEmpty {
                    Label("No commands yet.", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                        .glassRow()
                } else {
                    ForEach(Array(device.commands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { Divider().padding(.leading, 16) }
                        row(for: command)
                            .glassRow()
                    }
                }
            }

            GlassSection("Shortcuts") {
                Toggle(isOn: $shareShortcuts) {
                    Text("Show my Shortcuts on the phone")
                    Text("Lists every shortcut from the Shortcuts app in Run Command, so \(device.name) can run them on this Mac.")
                }
                .toggleStyle(.switch)
                .onChange(of: shareShortcuts) {
                    TetherService.shared.runCommandPlugin.refreshShortcuts()
                }
                .glassRow()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Command…", systemImage: "plus") {
                    editing = RemoteCommand(name: "", command: "")
                }
                .help("Add a command \(device.name) can run on this Mac")
            }
        }
        .sheet(item: $editing) { command in
            CommandEditor(command: command) { device.saveCommand($0) }
        }
        .confirmationDialog(
            "Delete “\(commandToDelete?.name ?? "")”?",
            isPresented: Binding(get: { commandToDelete != nil }, set: { if !$0 { commandToDelete = nil } }),
            presenting: commandToDelete
        ) { command in
            Button("Delete", role: .destructive) { device.deleteCommand(id: command.id) }
        }
    }

    private func row(for command: RemoteCommand) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Run") { device.executeCommand(id: command.id) }
                .glassButton()
            Menu {
                Button("Edit…") { editing = command }
                Button("Delete…", role: .destructive) { commandToDelete = command }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("More for \(command.name)")
        }
        .contextMenu {
            Button("Run") { device.executeCommand(id: command.id) }
            Button("Edit…") { editing = command }
            Divider()
            Button("Delete…", role: .destructive) { commandToDelete = command }
        }
    }
}

private struct CommandEditor: View {
    @State var command: RemoteCommand
    let onSave: (RemoteCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { command.name.isEmpty && command.command.isEmpty }
    private var canSave: Bool {
        !command.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(command: RemoteCommand, onSave: @escaping (RemoteCommand) -> Void) {
        _command = State(initialValue: command)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $command.name, prompt: Text("Sleep Display"))
                TextField("Command", text: $command.command, prompt: Text("pmset displaysleepnow"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)

            HStack {
                Text("Runs with /bin/sh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .navigationTitle(isNew ? "New Command" : "Edit Command")
    }
}

#if DEBUG
#Preview {
    CommandsPane(device: .mockConnectedPhone())
        .frame(width: 760, height: 480)
}
#endif
