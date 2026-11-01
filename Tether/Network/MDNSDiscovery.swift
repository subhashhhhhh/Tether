//
//  MDNSDiscovery.swift
//  Tether
//
//  Finds phones through KDE Connect's mDNS service and advertises this Mac, for
//  networks that drop broadcasts. Browsing misses a phone that rejoins within its
//  records' two-minute lifetime, so raw mDNS traffic is also watched for paired ids.
//

import Foundation
import Network
import dnssd

public nonisolated protocol MDNSDiscoveryDelegate: AnyObject, Sendable {
    /// A device's KDE Connect service resolved to an IPv4 address on this Mac's network.
    func didFindDevice(deviceId: String, host: String)
    /// A paired device's id appeared in another host's mDNS traffic.
    func didHear(deviceId: String)
}

public nonisolated final class MDNSDiscovery: @unchecked Sendable {
    public static let serviceType = "_kdeconnect._udp"
    private static let mdnsPort: UInt16 = 5353
    private static let mdnsGroup = "224.0.0.251"

    public weak var delegate: MDNSDiscoveryDelegate?

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "com.subhashh.tether.mdns", qos: .userInitiated)
    private var isRunning = false
    private var identity: DeviceInfo?
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var registration: DNSServiceRef?
    private var pathMonitor: NWPathMonitor?
    private var subnets: [(address: in_addr_t, mask: in_addr_t)] = []
    private var listenSource: DispatchSourceRead?
    private var watched: [String: [UInt8]] = [:]
    private var lastHeard: [String: Date] = [:]
    private var packetsHeard = 0
    private var readvertisePending = false
    private var readBuffer = [UInt8](repeating: 0, count: 9000)

    public init() {}

    public func start(advertising identity: DeviceInfo) {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.identity = identity
            self.subnets = Self.localSubnets()
            self.startMonitoringPath()
            self.startBrowsing()
            self.advertise(identity)
            self.restartListening()
            self.queue.asyncAfter(deadline: .now() + 300) {
                guard self.isRunning, self.listenSource != nil, self.packetsHeard == 0 else { return }
                TetherLog("[mDNS] No mDNS traffic heard in 5 minutes; is Local Network access allowed?")
            }
        }
    }

    public func stop() {
        queue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.browser?.cancel()
            self.browser = nil
            for connection in self.resolving.values {
                connection.cancel()
            }
            self.resolving.removeAll()
            self.stopListening()
            self.stopAdvertising()
        }
    }

    public func updateAdvertisement(_ identity: DeviceInfo) {
        queue.async {
            guard self.isRunning else { return }
            self.identity = identity
            self.stopAdvertising()
            self.advertise(identity)
        }
    }

    /// Listening only runs while at least one device is paired.
    public func setPairedDeviceIds(_ ids: Set<String>) {
        queue.async {
            // The paired list republishes on every connection; only a real change matters.
            guard ids != Set(self.watched.keys) else { return }
            self.watched = Dictionary(uniqueKeysWithValues: ids.map { ($0, Array($0.utf8)) })
            self.lastHeard = self.lastHeard.filter { ids.contains($0.key) }
            self.restartListening()
        }
    }

    public func resolve(deviceId: String) {
        queue.async {
            guard self.isRunning else { return }
            self.resolve(.service(name: deviceId, type: Self.serviceType, domain: "local.", interface: nil), deviceId: deviceId)
        }
    }

    // MARK: - Browsing

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .udp)
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            TetherLog("[mDNS] Browsing failed: \(error); retrying in 10 s")
            self?.queue.asyncAfter(deadline: .now() + 10) {
                guard let self, self.isRunning else { return }
                self.browser?.cancel()
                self.startBrowsing()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            for change in changes {
                switch change {
                case .added(let result), .changed(old: _, new: let result, flags: _):
                    // KDE Connect names its service after the device id.
                    if case .service(let deviceId, _, _, _) = result.endpoint {
                        self?.resolve(result.endpoint, deviceId: deviceId)
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        TetherLog("[mDNS] Browsing for \(Self.serviceType)")
    }

    /// A UDP connection is ready once its endpoint resolves; nothing is sent on it.
    private func resolve(_ endpoint: NWEndpoint, deviceId: String) {
        guard deviceId != identity?.deviceId, resolving[deviceId] == nil else { return }
        let parameters = NWParameters.udp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[deviceId] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                if case .hostPort(host: .ipv4(let address), port: _)? = connection?.currentPath?.remoteEndpoint {
                    self?.finishResolving(deviceId, host: address.rawValue.map(String.init).joined(separator: "."))
                } else {
                    self?.finishResolving(deviceId, host: nil, failure: "no IPv4 address")
                }
            case .failed(let error):
                self?.finishResolving(deviceId, host: nil, failure: "\(error)")
            case .cancelled:
                self?.finishResolving(deviceId, host: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.resolving[deviceId] === connection else { return }
            self.finishResolving(deviceId, host: nil, failure: "timed out after 5 s")
        }
    }

    private func finishResolving(_ deviceId: String, host: String?, failure: String? = nil) {
        guard let connection = resolving.removeValue(forKey: deviceId) else { return }
        connection.cancel()
        guard let host else {
            if let failure {
                TetherLog("[mDNS] Couldn't resolve \(deviceId): \(failure)")
            }
            return
        }
        // Only devices on a local Wi-Fi or Ethernet subnet, never over a VPN tunnel.
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1,
              subnets.contains(where: { $0.address & $0.mask == target.s_addr & $0.mask }) else {
            TetherLog("[mDNS] Ignoring \(deviceId) at \(host): not on a local network")
            return
        }
        TetherLog("[mDNS] Found \(deviceId) at \(host)")
        delegate?.didFindDevice(deviceId: deviceId, host: host)
    }

    // MARK: - Watching raw mDNS traffic

    /// Tether may start before Wi-Fi is up, or a cable may be plugged in later.
    private func startMonitoringPath() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.readvertiseIfNeeded()
            let subnets = Self.localSubnets()
            guard subnets.map(\.address) != self.subnets.map(\.address) else { return }
            self.subnets = subnets
            self.restartListening()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func restartListening() {
        stopListening()
        guard isRunning, !watched.isEmpty, !subnets.isEmpty else { return }
        startListening()
    }

    /// Bound to the group address, not INADDR_ANY: a socket bound to a multicast
    /// address only receives that group's traffic, so unicast mDNS replies to this
    /// Mac always stay with mDNSResponder, whichever socket was bound first.
    private func startListening() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            TetherLog("[mDNS] Couldn't create listening socket: errno \(errno)")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.mdnsPort.bigEndian
        inet_pton(AF_INET, Self.mdnsGroup, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            TetherLog("[mDNS] Couldn't bind port \(Self.mdnsPort) for listening: errno \(errno)")
            close(fd)
            return
        }

        var joined = 0
        for subnet in subnets {
            var request = ip_mreq()
            inet_pton(AF_INET, Self.mdnsGroup, &request.imr_multiaddr)
            request.imr_interface.s_addr = subnet.address
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joined += 1
            }
        }
        guard joined > 0 else {
            TetherLog("[mDNS] Couldn't join \(Self.mdnsGroup) on any local network: errno \(errno)")
            close(fd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readMDNSPackets(fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        listenSource = source
        TetherLog("[mDNS] Watching for paired devices rejoining the network")
    }

    private func stopListening() {
        listenSource?.cancel()
        listenSource = nil
    }

    private func readMDNSPackets(_ fd: Int32) {
        while true {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &readBuffer, readBuffer.count, 0, $0, &senderLength)
                }
            }
            let buffer = readBuffer
            guard count >= 12 else {
                if count < 0 { return }
                continue
            }
            packetsHeard += 1

            // Our own mDNSResponder's packets list paired devices' services too.
            guard !subnets.contains(where: { $0.address == sender.sin_addr.s_addr }) else { continue }
            // A device announces itself in responses and probes; other devices' plain
            // queries only list it as a known answer.
            let isResponse = buffer[2] & 0x80 != 0
            let authorityCount = Int(buffer[8]) << 8 | Int(buffer[9])
            guard isResponse || authorityCount > 0 else { continue }

            let now = Date()
            for (deviceId, idBytes) in watched where Self.contains(buffer, count: count, idBytes) {
                if let last = lastHeard[deviceId], now.timeIntervalSince(last) < 0.5 { continue }
                lastHeard[deviceId] = now
                delegate?.didHear(deviceId: deviceId)
            }
        }
    }

    private static func contains(_ buffer: [UInt8], count: Int, _ needle: [UInt8]) -> Bool {
        buffer.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { memmem(haystack.baseAddress, count, $0.baseAddress, needle.count) != nil }
        }
    }

    private static func localSubnets() -> [(address: in_addr_t, mask: in_addr_t)] {
        var subnets: [(in_addr_t, in_addr_t)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0,
                  String(cString: ptr.pointee.ifa_name).hasPrefix("en"),
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = ptr.pointee.ifa_netmask else { continue }
            let local = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            subnets.append((local, mask))
        }
        return subnets
    }

    // MARK: - Advertising

    /// Mirrors KDE Connect desktop: named after our device id, TXT id/name/type/protocol.
    private func advertise(_ info: DeviceInfo) {
        guard let tcpPort = info.tcpPort, tcpPort > 0 else { return }
        let txt = Self.txtRecord([
            ("id", info.deviceId),
            ("name", info.deviceName),
            ("type", info.deviceType.rawValue),
            ("protocol", String(info.protocolVersion))
        ])

        // No automatic renaming: phones read our device id from the service name.
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&ref, DNSServiceFlags(kDNSServiceFlagsNoAutoRename), 0, info.deviceId, Self.serviceType, nil, nil,
                               UInt16(tcpPort).bigEndian, UInt16(txt.count), raw.baseAddress, Self.registerReply, context)
        }
        guard error == kDNSServiceErr_NoError, let ref else {
            advertisingFailed(error)
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        registration = ref
        TetherLog("[mDNS] Advertising \(Self.serviceType) on TCP port \(tcpPort)")
    }

    private func stopAdvertising() {
        if let registration {
            DNSServiceRefDeallocate(registration)
            self.registration = nil
        }
    }

    // Called on `queue`, which the registration is scheduled on.
    private static let registerReply: DNSServiceRegisterReply = { _, _, errorCode, _, _, _, context in
        guard errorCode != kDNSServiceErr_NoError, let context else { return }
        Unmanaged<MDNSDiscovery>.fromOpaque(context).takeUnretainedValue().advertisingFailed(errorCode)
    }

    /// A name conflict usually means another device has our device id, but a second
    /// copy of Tether or a Bonjour Sleep Proxy after wake can cause one too, so it's
    /// retried slowly and on network changes. One retry is pending at a time.
    private func advertisingFailed(_ error: DNSServiceErrorType) {
        stopAdvertising()
        let isConflict = error == kDNSServiceErr_NameConflict
        TetherLog(isConflict
            ? "[mDNS] Another device is advertising our device id; retrying in 5 min"
            : "[mDNS] Advertising failed: error \(error); retrying in 10 s")
        guard !readvertisePending else { return }
        readvertisePending = true
        queue.asyncAfter(deadline: .now() + (isConflict ? 300 : 10)) {
            self.readvertisePending = false
            self.readvertiseIfNeeded()
        }
    }

    private func readvertiseIfNeeded() {
        guard isRunning, registration == nil, let identity else { return }
        advertise(identity)
    }

    /// DNS TXT record data: each entry is one length byte, then `key=value`.
    private static func txtRecord(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}
