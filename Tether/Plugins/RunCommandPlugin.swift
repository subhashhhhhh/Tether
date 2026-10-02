//
//  RunCommandPlugin.swift
//  Tether
//
//  Plugin allowing remote execution of predefined shell commands on macOS.
//

import Foundation
import Combine

public final class RunCommandPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public static let requestType = "kdeconnect.runcommand.request"
    public static let runCommandType = "kdeconnect.runcommand"
    public static let outputType = "kdeconnect.runcommand.output"

    public var supportedPacketTypes: [String] {
        [Self.requestType]
    }

    @Published public private(set) var commands: [RemoteCommand] = []
    @Published public private(set) var commandLogs: [String: [String]] = [:]

    private let lock = NSLock()
    private var activeProcesses: [UInt32: Process] = [:]
    private var executionCounter: UInt32 = 0
    private let userDefaultsKey = "tether_remote_commands"

    public init() {
        loadCommands()
    }

    public func onConnected(connection: DeviceConnection) {
        sendConfig(to: connection)
    }

    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
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

    public func addCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
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

    public func removeCommand(id: String, connection: DeviceConnection? = nil) {
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

    public func updateCommand(_ command: RemoteCommand, connection: DeviceConnection? = nil) {
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
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loaded = try? JSONDecoder().decode([RemoteCommand].self, from: data) {
            self.commands = loaded
        } else {
            self.commands = RemoteCommand.defaultCommands
            saveCommands()
        }
    }

    private func saveCommands() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    public func sendConfig(to connection: DeviceConnection) {
        var commandMap: [String: [String: String]] = [:]
        for cmd in commands {
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
        TetherLog("[RunCommandPlugin] Sent commandList (\(commands.count) commands) to \(connection.peerDeviceInfo?.deviceName ?? "device")")
    }

    // MARK: - Process Execution

    public func startCommand(key: String, connection: DeviceConnection?) {
        guard let command = commands.first(where: { $0.id == key }) else {
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
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.command]

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

    public func stopAllProcesses() {
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
