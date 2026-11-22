//
//  TailscaleDiscovery.swift
//  Tether
//
//  Finds the user's own phones on their Tailscale network, so Tether can reach
//  them when they're not on the same Wi-Fi. Tailscale doesn't carry the UDP
//  broadcasts KDE Connect discovery relies on, but it does carry unicast, so
//  sending our identity straight to each phone's tailnet address is enough for
//  the phone to connect back.
//
//  Everything comes from the local `tailscale status --json`; Tether never
//  talks to Tailscale's servers.
//

import Foundation

enum TailscaleStatus: Sendable, Equatable {
    case notInstalled
    /// Installed, but logged out, stopped or not responding.
    case notRunning
    case running(selfIP: String, phones: [TailscalePeer])
}

struct TailscalePeer: Sendable, Equatable, Identifiable {
    let name: String
    let ip: String
    let os: String
    var id: String { ip }
}

nonisolated enum TailscaleDiscovery {
    /// Whether an address is on a tailnet: 100.64.0.0/10, or Tailscale's
    /// IPv6 range fd7a:115c:a1e0::/48.
    static func isTailscaleAddress(_ host: String) -> Bool {
        if host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Settings › General › "Find devices over Tailscale". On unless turned off.
    static let enabledKey = "tether_tailscale_discovery"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The Mac app bundles its CLI; Homebrew and the standalone package install one on PATH.
    private static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale"
    ]

    /// Only peers that can run KDE Connect as a phone or tablet.
    private static let phoneOperatingSystems: Set<String> = ["android", "ios"]

    /// Reads the tailnet. Blocking (spawns the CLI, up to a few seconds), so
    /// call it off the main thread.
    static func currentStatus() -> TailscaleStatus {
        guard let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .notInstalled
        }
        guard let json = run(cli, arguments: ["status", "--json"], timeout: 4) else {
            return .notRunning
        }
        return parse(json)
    }

    static func parse(_ json: Data) -> TailscaleStatus {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              root["BackendState"] as? String == "Running",
              let me = root["Self"] as? [String: Any],
              let selfIP = firstIPv4(me["TailscaleIPs"]) else {
            return .notRunning
        }

        // Only devices logged in as the same user. Machines shared into the
        // tailnet by other people must not receive this Mac's identity.
        let myUser = me["UserID"].map { "\($0)" }
        let peers = (root["Peer"] as? [String: [String: Any]] ?? [:]).values

        let phones = peers.compactMap { peer -> TailscalePeer? in
            guard peer["Online"] as? Bool == true,
                  let os = (peer["OS"] as? String)?.lowercased(),
                  phoneOperatingSystems.contains(os),
                  peer["UserID"].map({ "\($0)" }) == myUser,
                  let ip = firstIPv4(peer["TailscaleIPs"]) else { return nil }
            let name = (peer["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ip
            return TailscalePeer(name: name, ip: ip, os: os)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return .running(selfIP: selfIP, phones: phones)
    }

    /// Discovery announces over IPv4; Tailscale gives every device a stable 100.x address.
    private static func firstIPv4(_ value: Any?) -> String? {
        (value as? [String])?.first { !$0.contains(":") }
    }

    private static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // The binary inside Tailscale.app is both the GUI and the CLI. Started
        // from an app (no TERM/SHLVL in the environment) it tries to launch the
        // GUI and prints an error, still exiting 0. This forces CLI mode.
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        // Read concurrently so a large status can't fill the pipe and stall the CLI.
        var data = Data()
        let reader = DispatchQueue(label: "com.subhashh.tether.tailscale.read")
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        reader.sync {}
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: - Address resolution

nonisolated enum HostResolver {
    /// Resolves a host name (e.g. a Tailscale MagicDNS name) or dotted IPv4
    /// string to an IPv4 address. Blocking; call it off the main thread.
    static func ipv4(for host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        guard let address = first.pointee.ai_addr else { return nil }
        let sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return String(cString: inet_ntoa(sin.sin_addr))
    }
}
