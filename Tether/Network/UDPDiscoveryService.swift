//
//  UDPDiscoveryService.swift
//  Tether
//

import Foundation
import Darwin

public protocol UDPDiscoveryDelegate: AnyObject, Sendable {
    func didDiscoverDevice(host: String, port: Int, deviceInfo: DeviceInfo)
    func isDeviceConnected(deviceId: String) -> Bool
    /// Addresses of devices that are connected right now.
    func connectedHosts() -> Set<String>
}

public final class UDPDiscoveryService: @unchecked Sendable {
    public static let defaultPort: UInt16 = 1716
    public weak var delegate: UDPDiscoveryDelegate?

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.subhashh.tether.udp", qos: .userInitiated)
    private var broadcastTimer: DispatchSourceTimer?
    private var isRunning = false
    private var knownTargetIPs = Set<String>()
    /// The user's phones on their Tailscale network, refreshed by TetherService.
    private var tailscaleTargetIPs = Set<String>()
    private var lastDirectResponse: [String: Date] = [:]
    /// Which device each address belongs to. A phone has several (Wi-Fi,
    /// Tailscale, an old network), and announcing to any of them while it's
    /// connected makes KDE Connect open a new connection and drop the current
    /// one. Kept across launches: Tailscale addresses don't change.
    private var hostOwners: [String: String] = [:]
    private static let hostOwnersKey = "tether_host_owners"
    private var lastLoggedBroadcastTargets = Set<String>()
    private var hasLoggedOutboundPacket = false
    /// Bumped by each new sweep, so an older one still pausing stops.
    private var sweepGeneration = 0

    public init() {
        hostOwners = UserDefaults.standard.dictionary(forKey: Self.hostOwnersKey) as? [String: String] ?? [:]
        if let lastIP = UserDefaults.standard.string(forKey: "tether_last_peer_ip") {
            knownTargetIPs.insert(lastIP)
        }
        if let manualIPs = UserDefaults.standard.stringArray(forKey: "tether_manual_peer_ips") {
            for ip in manualIPs {
                knownTargetIPs.insert(ip)
            }
        }
    }

    public func addKnownTarget(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.knownTargetIPs.insert(trimmed)
            var current = UserDefaults.standard.stringArray(forKey: "tether_manual_peer_ips") ?? []
            if !current.contains(trimmed) {
                current.append(trimmed)
                UserDefaults.standard.set(current, forKey: "tether_manual_peer_ips")
            }
        }
    }

    /// Records that `host` is one of `deviceId`'s addresses.
    public func noteHost(_ host: String, belongsTo deviceId: String) {
        queue.async {
            guard self.hostOwners[host] != deviceId else { return }
            self.hostOwners[host] = deviceId
            // Bounded, for networks that hand out a new address every visit.
            if self.hostOwners.count > 64 {
                self.hostOwners = Dictionary(uniqueKeysWithValues: self.hostOwners.suffix(48))
            }
            UserDefaults.standard.set(self.hostOwners, forKey: Self.hostOwnersKey)
        }
    }

    /// Whether `host` is an address of a device that's connected right now,
    /// by any of its addresses.
    private func belongsToConnectedDevice(_ host: String, connectedHosts: Set<String>) -> Bool {
        if connectedHosts.contains(host) { return true }
        guard let owner = hostOwners[host] else { return false }
        return delegate?.isDeviceConnected(deviceId: owner) ?? false
    }

    /// Replaces the Tailscale targets, announcing ourselves to any new ones right
    /// away so a phone that just came online doesn't wait for the next cycle.
    public func setTailscaleTargets(_ ips: Set<String>) {
        queue.async {
            let connected = self.delegate?.connectedHosts() ?? []
            let added = ips.subtracting(self.tailscaleTargetIPs).filter { !self.belongsToConnectedDevice($0, connectedHosts: connected) }
            self.tailscaleTargetIPs = ips
            guard !added.isEmpty,
                  let data = try? DeviceIdentity.shared.toDeviceInfo().toUdpDiscoveryPacket().serialize() else { return }
            TetherLog("[UDPDiscovery] Announcing to Tailscale peers: \(added.sorted().joined(separator: ", "))")
            for ip in added {
                self.sendDatagram(data: data, toIP: ip)
            }
        }
    }

    public func start(listenPort: UInt16 = UDPDiscoveryService.defaultPort) {
        guard !isRunning else { return }
        isRunning = true

        setupSocket(port: listenPort)
        startBroadcasting()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        broadcastTimer?.cancel()
        broadcastTimer = nil

        // The cancel handler closes the fd; closing it here too could hit a reused number.
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    private func setupSocket(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            TetherLog("[UDPDiscovery] Failed to create UDP socket: \(errno)")
            return
        }

        // Behind a socket content filter a blocking send can sleep forever, and this
        // queue also receives, so sends must never block.
        let fileFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, fileFlags | O_NONBLOCK)

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult < 0 {
            TetherLog("[UDPDiscovery] Failed to bind UDP socket on port \(port): \(errno)")
            close(fd)
            return
        }

        self.socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readDatagram()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.readSource = source
        TetherLog("[UDPDiscovery] Listening for UDP discovery broadcasts on port \(port)")
    }

    private func readDatagram() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &senderAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(socketFD, &buffer, buffer.count, 0, $0, &senderLen)
            }
        }

        guard bytesRead > 0 else { return }

        let senderIP = String(cString: inet_ntoa(senderAddr.sin_addr))
        let data = Data(buffer[0..<bytesRead])

        guard let packet = try? NetworkPacket.unserialize(from: data),
              let deviceInfo = DeviceInfo.from(packet: packet) else {
            return
        }

        // Ignore our own broadcast
        if deviceInfo.deviceId == DeviceIdentity.shared.deviceId {
            return
        }

        let tcpPort = deviceInfo.tcpPort ?? Int(UDPDiscoveryService.defaultPort)
        TetherLog("[UDPDiscovery] Received UDP discovery from: \(deviceInfo.deviceName) (\(deviceInfo.deviceId)) at \(senderIP):\(tcpPort)")

        knownTargetIPs.insert(senderIP)
        noteHost(senderIP, belongsTo: deviceInfo.deviceId)
        UserDefaults.standard.set(senderIP, forKey: "tether_last_peer_ip")

        let isConnected = delegate?.isDeviceConnected(deviceId: deviceInfo.deviceId) ?? false

        // Only send direct unicast presence if the device is NOT already actively connected
        // and we haven't responded to this sender recently
        if !isConnected {
            let lastSent = lastDirectResponse[senderIP] ?? .distantPast
            if Date().timeIntervalSince(lastSent) > 30 {
                lastDirectResponse[senderIP] = Date()
                sendDirectPresence(to: senderIP)
            }
        }

        delegate?.didDiscoverDevice(host: senderIP, port: tcpPort, deviceInfo: deviceInfo)
    }

    /// Announces this Mac. `routine` is the periodic background announcement:
    /// it skips devices that are already connected, because KDE Connect on
    /// Android answers every announcement by opening a fresh connection, which
    /// would otherwise churn a healthy one every cycle. `sweepSubnet` also sends
    /// to every address on the local subnets; it's only for explicit requests.
    public func broadcastPresence(tcpPort: Int? = nil, routine: Bool = false, sweepSubnet: Bool = false) {
        let packet = DeviceIdentity.shared.toDeviceInfo(tcpPort: tcpPort).toUdpDiscoveryPacket()
        guard let data = try? packet.serialize() else { return }

        if !hasLoggedOutboundPacket {
            hasLoggedOutboundPacket = true
            let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<undecodable>"
            TetherLog("[UDPDiscovery] Outbound discovery packet: \(json)")
        }

        queue.async {
            let sent = self.sendBroadcastData(data, routine: routine)
            if sweepSubnet {
                self.startSweep(data, skipping: Set(sent))
            }
        }
    }

    private var lastDirectPresenceSent: [String: Date] = [:]

    public func sendDirectPresence(to host: String, tcpPort: Int? = nil, throttled: Bool = true) {
        let packet = DeviceIdentity.shared.toDeviceInfo(tcpPort: tcpPort).toUdpDiscoveryPacket()
        guard let data = try? packet.serialize() else { return }

        queue.async {
            let last = self.lastDirectPresenceSent[host] ?? .distantPast
            guard !throttled || Date().timeIntervalSince(last) > 10 else { return }
            self.lastDirectPresenceSent[host] = Date()
            self.sendDatagram(data: data, toIP: host)
        }
    }

    private func startBroadcasting() {
        // Initial announcement to every candidate, connected phones included
        broadcastPresence()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(45))
        timer.setEventHandler { [weak self] in
            self?.broadcastPresence(routine: true)
        }
        timer.resume()
        self.broadcastTimer = timer
    }

    // MARK: - Active Kernel ARP Neighbor Discovery
    private func getKernelARPAddresses() -> [String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len: Int = 0
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 || len == 0 {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: len)
        if sysctl(&mib, 6, &buffer, &len, nil, 0) < 0 {
            return []
        }

        var ips: [String] = []
        var offset = 0
        while offset < len {
            let rtm = buffer.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: rt_msghdr.self)
            }
            let rtmMsgLen = Int(rtm.rtm_msglen)
            if rtmMsgLen == 0 { break }

            let sinOffset = offset + MemoryLayout<rt_msghdr>.size
            let sin = buffer.withUnsafeBytes { raw in
                raw.load(fromByteOffset: sinOffset, as: sockaddr_in.self)
            }
            if sin.sin_family == sa_family_t(AF_INET) {
                let ipStr = String(cString: inet_ntoa(sin.sin_addr))
                // Skip incomplete entries: nothing answered ARP there.
                let sinLen = max(Int(sin.sin_len), MemoryLayout<UInt32>.size)
                let sdlOffset = sinOffset + ((sinLen + 3) & ~3)
                let resolved = sdlOffset + 7 <= offset + rtmMsgLen
                    && buffer[sdlOffset + 1] == UInt8(AF_LINK)
                    && buffer[sdlOffset + 6] > 0
                let isMulticast = UInt32(bigEndian: sin.sin_addr.s_addr) >> 28 == 0xE
                let isBroadcast = rtm.rtm_flags & RTF_BROADCAST != 0
                if resolved && !isMulticast && !isBroadcast && !ipStr.hasPrefix("127.") {
                    if !ips.contains(ipStr) {
                        ips.append(ipStr)
                    }
                }
            }
            offset += rtmMsgLen
        }
        return ips
    }

    private func getBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return ["255.255.255.255"] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isBroadcast = (flags & IFF_BROADCAST) != 0

            guard isUp && isRunning && !isLoopback && isBroadcast else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            if let broadaddr = ptr.pointee.ifa_dstaddr, broadaddr.pointee.sa_family == sa_family_t(AF_INET) {
                let bAddr = broadaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ipStr = String(cString: inet_ntoa(bAddr.sin_addr))
                if !addresses.contains(ipStr) {
                    addresses.append(ipStr)
                }
            }
        }

        if addresses.isEmpty {
            addresses.append("255.255.255.255")
        }
        return addresses
    }

    // MARK: - Subnet Sweep

    private func startSweep(_ data: Data, skipping sent: Set<String>) {
        let targets = getLocalSubnetSweepTargets().filter { !sent.contains($0) }
        guard !targets.isEmpty else { return }
        sweepGeneration += 1
        TetherLog("[UDPDiscovery] Sweeping \(targets.count) local subnet addresses")
        continueSweep(data, targets: targets, from: 0, generation: sweepGeneration, started: Date(), pauses: 0)
    }

    /// Behind a content filter only a few dozen sends fit in the buffer while the
    /// filter decides, so a full buffer pauses the sweep briefly instead of ending it.
    private func continueSweep(_ data: Data, targets: [String], from start: Int, generation: Int, started: Date, pauses: Int) {
        guard generation == sweepGeneration else { return }
        var index = start
        while index < targets.count, sendDatagram(data: data, toIP: targets[index], logFull: false) {
            index += 1
        }
        let elapsed = Date().timeIntervalSince(started)
        guard index < targets.count, elapsed < 5 else {
            TetherLog("[UDPDiscovery] Sweep sent \(index) of \(targets.count) in \(String(format: "%.1f", elapsed)) s, pausing \(pauses) times for a full send buffer")
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            self.continueSweep(data, targets: targets, from: index, generation: generation, started: started, pauses: pauses + 1)
        }
    }

    /// Every host address on each local broadcast subnet up to /22, except our own.
    private func getLocalSubnetSweepTargets() -> [String] {
        var targets: [String] = []
        var seen = Set<UInt32>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0, (flags & IFF_BROADCAST) != 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = ptr.pointee.ifa_netmask else { continue }

            let own = UInt32(bigEndian: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let mask = UInt32(bigEndian: netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let hostBits = ~mask
            guard hostBits >= 3, hostBits <= 1023 else { continue }

            let network = own & mask
            for host in 1..<hostBits {
                let address = network | host
                guard address != own, seen.insert(address).inserted else { continue }
                targets.append("\(address >> 24).\(address >> 16 & 255).\(address >> 8 & 255).\(address & 255)")
            }
        }
        return targets
    }

    @discardableResult
    private func sendBroadcastData(_ data: Data, routine: Bool = false) -> [String] {
        guard socketFD >= 0 else { return [] }
        let connected = delegate?.connectedHosts() ?? []

        // 1. Known past & manual target IPs and tailnet phones, first in case the round is cut short.
        var targets = Array(knownTargetIPs.union(tailscaleTargetIPs))

        // 2. A broadcast reaches connected phones too, so a routine announcement
        // only broadcasts while nothing is connected.
        if !routine || connected.isEmpty {
            for ip in getBroadcastAddresses() where !targets.contains(ip) {
                targets.append(ip)
            }
        }

        // 3. Active ARP neighbors from the kernel routing cache
        for ip in getKernelARPAddresses() where !targets.contains(ip) {
            targets.append(ip)
        }

        if routine {
            targets.removeAll { belongsToConnectedDevice($0, connectedHosts: connected) }
        }
        guard !targets.isEmpty else { return [] }

        if Set(targets) != lastLoggedBroadcastTargets {
            lastLoggedBroadcastTargets = Set(targets)
            TetherLog("[UDPDiscovery] Broadcasting discovery to \(targets.joined(separator: ", "))")
        }

        var sentCount = 0
        for ip in targets {
            guard sendDatagram(data: data, toIP: ip) else { break }
            sentCount += 1
        }
        return Array(targets.prefix(sentCount))
    }

    /// Returns false when the send buffer is full, so a round can stop early.
    @discardableResult
    private func sendDatagram(data: Data, toIP ip: String, logFull: Bool = true) -> Bool {
        guard socketFD >= 0 else { return false }
        var targetAddr = sockaddr_in()
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = in_port_t(UDPDiscoveryService.defaultPort).bigEndian

        if inet_pton(AF_INET, ip, &targetAddr.sin_addr) <= 0 {
            return true
        }

        let (sent, err) = data.withUnsafeBytes { rawBuffer -> (Int, Int32) in
            guard let baseAddress = rawBuffer.baseAddress else { return (0, 0) }
            let sent = withUnsafePointer(to: &targetAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(self.socketFD, baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return (sent, errno)
        }
        guard sent < 0 else { return true }
        if err == EAGAIN || err == ENOBUFS {
            if logFull {
                TetherLog("[UDPDiscovery] Send buffer full at \(ip) (errno \(err)); skipping the rest of this round")
            }
            return false
        }
        if err != EHOSTUNREACH && err != ENETUNREACH && err != EHOSTDOWN {
            TetherLog("[UDPDiscovery] Failed to send discovery to \(ip): errno \(err)")
        }
        return true
    }
}
