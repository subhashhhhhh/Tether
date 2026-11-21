//
//  RunCommandPlugin.swift
//  Tether
//
//  Plugin allowing remote execution of predefined shell commands on macOS.
//

import Foundation
import Combine

final class RunCommandPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    static let requestType = PacketType.runcommandRequest
    static let runCommandType = PacketType.runcommand
    static let outputType = PacketType.runcommandOutput

    var supportedPacketTypes: [String] {
        [Self.requestType]
    }

    @Published private(set) var commands: [RemoteCommand] = []
    @Published private(set) var commandLogs: [String: [String]] = [:]

    private let lock = NSLock()
    private var activeProcesses: [UInt32: Process] = [:]
    private var executionCounter: UInt32 = 0
    private let userDefaultsKey = "tether_remote_commands"

    /// Commands › "Show my Shortcuts on the phone". Off by default: a shortcut
    /// can do anything, so exposing them is the user's choice.
    static let shortcutsKey = "tether_share_shortcuts"
    static let shortcutPrefix = "shortcut:"
    /// The user's Shortcuts, as commands, when sharing them is on.
    private var shortcutCommands: [RemoteCommand] = []
    private var connections: [String: DeviceConnection] = [:]
    private let defaults: UserDefaults

    /// Tests pass their own `defaults` so they never touch the saved commands.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadCommands()
    }

    func onConnected(connection: DeviceConnection) {
        if let id = connection.peerDeviceInfo?.deviceId {
            lock.withLock { connections[id] = connection }
        }
        sendConfig(to: connection)
        refreshShortcuts()
    }

    func onDisconnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        lock.withLock { if connections[id] === connection { connections[id] = nil } }
    }

    // MARK: - Shortcuts

    /// Reads the user's Shortcuts and sends the updated list to every
    /// connected phone. Also called when the setting changes.
    func refreshShortcuts() {
        let enabled = defaults.bool(forKey: Self.shortcutsKey)
        DispatchQueue.global(qos: .utility).async {
            let names = enabled ? Self.shortcutNames() : []
            let commands = names.map {
                RemoteCommand(id: Self.shortcutPrefix + $0, name: $0, command: "Shortcut: \($0)")
            }
            let (changed, targets) = self.lock.withLock {
                let changed = commands != self.shortcutCommands
                self.shortcutCommands = commands
                return (changed, Array(self.connections.values))
            }
            guard changed else { return }
            TetherLog("[RunCommandPlugin] Sharing \(commands.count) Shortcut(s)")
            for connection in targets { self.sendConfig(to: connection) }
        }
    }

    private static func shortcutNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        if packet.bool(for: "requestCommandList") {
            sendConfig(to: connection)
            return
        }

        if let key = packet.string(for: "key") {
            startCommand(key: key, connection: connection)
        } else if packet.bool(for: "stop") {
            stopAllProcesses()
        }
    }

    // MARK: - Command Management

    func addCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
        lock.withLock {
            self.commands.append(command)
            self.saveCommands()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    func removeCommand(id: String, connection: DeviceConnection? = nil) {
        lock.withLock {
            self.commands.removeAll(where: { $0.id == id })
            self.saveCommands()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    func updateCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
        lock.withLock {
            if let index = self.commands.firstIndex(where: { $0.id == command.id }) {
                self.commands[index] = command
                self.saveCommands()
            }
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        if let conn = connection {
            sendConfig(to: conn)
        }
    }

    private func loadCommands() {
        if let data = defaults.data(forKey: userDefaultsKey),
           let loaded = try? JSONDecoder().decode([RemoteCommand].self, from: data) {
            self.commands = loaded
        } else {
            self.commands = RemoteCommand.defaultCommands
            saveCommands()
        }
    }

    private func saveCommands() {
        if let data = try? JSONEncoder().encode(commands) {
            defaults.set(data, forKey: userDefaultsKey)
        }
    }

    func sendConfig(to connection: DeviceConnection) {
        var commandMap: [String: [String: String]] = [:]
        let shortcuts = lock.withLock { shortcutCommands }
        for cmd in commands + shortcuts {
            commandMap[cmd.id] = [
                "name": cmd.name,
                "command": cmd.command
            ]
        }

        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: commandMap, options: []),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "{}"
        }

        let packet = NetworkPacket(
            type: Self.runCommandType,
            body: [
                "commandList": AnyCodable(jsonString),
                "canAddCommand": AnyCodable(true)
            ]
        )
        connection.send(packet: packet)
        TetherLog("[RunCommandPlugin] Sent commandList (\(commandMap.count) commands) to \(connection.peerDeviceInfo?.deviceName ?? "device")")
    }

    // MARK: - Process Execution

    func startCommand(key: String, connection: DeviceConnection?) {
        let shortcuts = lock.withLock { shortcutCommands }
        guard let command = (commands + shortcuts).first(where: { $0.id == key }) else {
            TetherLog("[RunCommandPlugin] Unknown command key: \(key)")
            return
        }

        let currentId: UInt32 = lock.withLock {
            self.executionCounter += 1
            return self.executionCounter
        }

        TetherLog("[RunCommandPlugin] Starting command [\(currentId)]: \(command.name) ('\(command.command)')")

        if let conn = connection {
            let startPacket = NetworkPacket(
                type: Self.outputType,
                body: [
                    "commandStarted": AnyCodable(true),
                    "command": AnyCodable(command.command),
                    "id": AnyCodable(Int(currentId))
                ]
            )
            conn.send(packet: startPacket)
        }

        DispatchQueue.main.async {
            self.appendLog(commandId: command.id, line: "▶ Running: \(command.command)")
        }

        let process = Process()
        if command.id.hasPrefix(Self.shortcutPrefix) {
            // Run by name, never through the shell: a shortcut's name is text.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", String(command.id.dropFirst(Self.shortcutPrefix.count))]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command.command]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.withLock {
            self.activeProcesses[currentId] = process
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak connection] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }

            DispatchQueue.main.async {
                for line in lines {
                    self?.appendLog(commandId: command.id, line: line)
                }
            }

            if let conn = connection, !lines.isEmpty {
                let outPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandOutput": AnyCodable(true),
                        "stdout": AnyCodable(lines),
                        "stderr": AnyCodable([] as [String]),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: outPacket)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak connection] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }

            DispatchQueue.main.async {
                for line in lines {
                    self?.appendLog(commandId: command.id, line: "stderr: \(line)")
                }
            }

            if let conn = connection, !lines.isEmpty {
                let outPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandOutput": AnyCodable(true),
                        "stdout": AnyCodable([] as [String]),
                        "stderr": AnyCodable(lines),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: outPacket)
            }
        }

        process.terminationHandler = { [weak self, weak connection] proc in
            let exitCode = proc.terminationStatus
            let success = (exitCode == 0)

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            self?.lock.withLock {
                _ = self?.activeProcesses.removeValue(forKey: currentId)
            }

            DispatchQueue.main.async {
                self?.appendLog(commandId: command.id, line: "■ Finished with exit code \(exitCode)")
            }

            if let conn = connection {
                let finishPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandFinished": AnyCodable(true),
                        "success": AnyCodable(success),
                        "exitCode": AnyCodable(Int(exitCode)),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: finishPacket)
            }
            TetherLog("[RunCommandPlugin] Command [\(currentId)] finished with exit code \(exitCode)")
        }

        do {
            try process.run()
        } catch {
            TetherLog("[RunCommandPlugin] Failed to run process: \(error)")
            lock.withLock {
                _ = self.activeProcesses.removeValue(forKey: currentId)
            }
            if let conn = connection {
                let finishPacket = NetworkPacket(
                    type: Self.outputType,
                    body: [
                        "commandFinished": AnyCodable(true),
                        "success": AnyCodable(false),
                        "exitCode": AnyCodable(-1),
                        "id": AnyCodable(Int(currentId))
                    ]
                )
                conn.send(packet: finishPacket)
            }
        }
    }

    func stopAllProcesses() {
        lock.withLock {
            for (_, proc) in self.activeProcesses {
                proc.terminate()
            }
            self.activeProcesses.removeAll()
        }
    }

    private func appendLog(commandId: String, line: String) {
        var existing = commandLogs[commandId] ?? []
        existing.append(line)
        if existing.count > 100 {
            existing.removeFirst(existing.count - 100)
        }
        commandLogs[commandId] = existing
    }
}
