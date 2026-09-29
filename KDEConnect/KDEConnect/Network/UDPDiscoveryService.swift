//
//  UDPDiscoveryService.swift
//  KDEConnect
//

import Foundation
import Darwin

public protocol UDPDiscoveryDelegate: AnyObject, Sendable {
    func didDiscoverDevice(host: String, port: Int, deviceInfo: DeviceInfo)
}

public final class UDPDiscoveryService: @unchecked Sendable {
    public static let defaultPort: UInt16 = 1716
    public weak var delegate: UDPDiscoveryDelegate?

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "org.kde.kdeconnect.udp", qos: .userInitiated)
    private var broadcastTimer: DispatchSourceTimer?
    private var isRunning = false

    public init() {}

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

        readSource?.cancel()
        readSource = nil

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func setupSocket(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            KDLog("[UDPDiscovery] Failed to create UDP socket: \(errno)")
            return
        }

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
            KDLog("[UDPDiscovery] Failed to bind UDP socket on port \(port): \(errno)")
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
        KDLog("[UDPDiscovery] Listening for UDP discovery broadcasts on port \(port)")
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
        KDLog("[UDPDiscovery] Received UDP discovery from: \(deviceInfo.deviceName) (\(deviceInfo.deviceId)) at \(senderIP):\(tcpPort)")

        // Respond directly to this device over UDP unicast so it reliably sees us
        sendDirectPresence(to: senderIP)

        delegate?.didDiscoverDevice(host: senderIP, port: tcpPort, deviceInfo: deviceInfo)
    }

    public func broadcastPresence(tcpPort: Int = 1716) {
        let packet = DeviceIdentity.shared.toDeviceInfo(tcpPort: tcpPort).toUdpDiscoveryPacket()
        guard let data = try? packet.serialize() else { return }

        queue.async {
            self.sendBroadcastData(data)
        }
    }

    public func sendDirectPresence(to host: String, tcpPort: Int = 1716) {
        let packet = DeviceIdentity.shared.toDeviceInfo(tcpPort: tcpPort).toUdpDiscoveryPacket()
        guard let data = try? packet.serialize() else { return }

        queue.async {
            self.sendDatagram(data: data, toIP: host)
        }
    }

    private func startBroadcasting() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(4))
        timer.setEventHandler { [weak self] in
            self?.broadcastPresence()
        }
        timer.resume()
        self.broadcastTimer = timer
    }

    private func getBroadcastAddresses() -> [String] {
        var addresses = ["255.255.255.255"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            guard isUp && isRunning && !isLoopback else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            if let broadaddr = ptr.pointee.ifa_dstaddr, broadaddr.pointee.sa_family == sa_family_t(AF_INET) {
                let bAddr = broadaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ipStr = String(cString: inet_ntoa(bAddr.sin_addr))
                if !addresses.contains(ipStr) {
                    addresses.append(ipStr)
                }
            }
        }
        return addresses
    }

    private func sendBroadcastData(_ data: Data) {
        guard socketFD >= 0 else { return }
        let targets = getBroadcastAddresses()
        for ip in targets {
            sendDatagram(data: data, toIP: ip)
        }
    }

    private func sendDatagram(data: Data, toIP ip: String) {
        guard socketFD >= 0 else { return }
        var targetAddr = sockaddr_in()
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = in_port_t(UDPDiscoveryService.defaultPort).bigEndian

        if inet_pton(AF_INET, ip, &targetAddr.sin_addr) <= 0 {
            return
        }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &targetAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(self.socketFD, baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
