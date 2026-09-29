//
//  RemoteCommand.swift
//  Tether
//
//  Data model representing a user-defined shell command executable from the phone.
//

import Foundation

public struct RemoteCommand: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String = UUID().uuidString, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    public static let defaultCommands: [RemoteCommand] = [
        RemoteCommand(
            id: "cmd_say_hello",
            name: "Say Hello",
            command: "osascript -e 'display notification \"Hello from Tether!\" with title \"Tether\"'"
        ),
        RemoteCommand(
            id: "cmd_sleep_display",
            name: "Sleep Display",
            command: "pmset displaysleepnow"
        ),
        RemoteCommand(
            id: "cmd_mute_audio",
            name: "Toggle Mute",
            command: "osascript -e 'set volume output muted (not (output muted of (get volume settings)))'"
        )
    ]
}
