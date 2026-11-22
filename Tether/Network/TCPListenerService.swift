//
//  TCPListenerService.swift
//  Tether
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
    private let queue = DispatchQueue(label: "com.subhashh.tether.tcplistener", qos: .userInitiated)
    private var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        for port in TCPListenerService.minPort...TCPListenerService.maxPort {
            if bindAndListen(on: port) {
                activePort = port
                DeviceIdentity.shared.advertisedTCPPort = Int(port)
                TetherLog("[TCPListener] Listening for incoming KDE Connect TCP connections on port \(port)")
                return
            }
        }
        TetherLog("[TCPListener] Failed to bind to any port in range \(TCPListenerService.minPort)-\(TCPListenerService.maxPort)")
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
        // IPv4 and IPv6, as KDE Connect desktop listens.
        let fd = SocketAddress.listener(port: port, reusePort: true)
        guard fd >= 0 else { return false }

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
        guard let (clientFD, clientIP, clientPort) = SocketAddress.accept(serverFD) else { return }

        TetherLog("[TCPListener] Accepted incoming connection from \(clientIP):\(clientPort)")
        delegate?.didAcceptConnection(socketFD: clientFD, clientIP: clientIP, clientPort: clientPort)
    }
}
