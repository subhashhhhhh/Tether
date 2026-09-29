//
//  TCPListenerService.swift
//  KDEConnect
//

import Foundation
import Darwin

public protocol TCPListenerDelegate: AnyObject, Sendable {
    func didAcceptConnection(socketFD: Int32, clientIP: String, clientPort: Int)
}

public final class TCPListenerService: @unchecked Sendable {
    public static let minPort: UInt16 = 1716
    public static let maxPort: UInt16 = 1764

    public weak var delegate: TCPListenerDelegate?
    public private(set) var activePort: UInt16 = 0

    private var serverFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "org.kde.kdeconnect.tcplistener", qos: .userInitiated)
    private var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        for port in TCPListenerService.minPort...TCPListenerService.maxPort {
            if bindAndListen(on: port) {
                activePort = port
                KDLog("[TCPListener] Listening for incoming KDE Connect TCP connections on port \(port)")
                return
            }
        }
        KDLog("[TCPListener] Failed to bind to any port in range \(TCPListenerService.minPort)-\(TCPListenerService.maxPort)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        readSource?.cancel()
        readSource = nil

        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        activePort = 0
    }

    private func bindAndListen(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            return false
        }

        guard listen(fd, 10) == 0 else {
            close(fd)
            return false
        }

        self.serverFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptIncoming()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.readSource = source
        return true
    }

    private func acceptIncoming() {
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFD, $0, &clientLen)
            }
        }

        guard clientFD >= 0 else { return }

        let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
        let clientPort = Int(UInt16(bigEndian: clientAddr.sin_port))

        KDLog("[TCPListener] Accepted incoming connection from \(clientIP):\(clientPort)")
        delegate?.didAcceptConnection(socketFD: clientFD, clientIP: clientIP, clientPort: clientPort)
    }
}
