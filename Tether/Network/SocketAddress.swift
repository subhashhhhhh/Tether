//
//  SocketAddress.swift
//  Tether
//
//  IPv4 and IPv6 addresses for the TCP sockets. Listeners are dual-stack,
//  as KDE Connect desktop's are, so a phone can connect over either; an
//  IPv4 peer then shows up as an IPv4-mapped IPv6 address, which is turned
//  back into plain IPv4 so it matches the address discovery saw.
//

import Darwin

nonisolated enum SocketAddress {
    /// A socket address for an IPv4 or IPv6 literal ("192.168.1.5",
    /// "fe80::1%en0"), or nil for anything else.
    static func make(host: String, port: UInt16) -> (storage: sockaddr_storage, length: socklen_t)? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { buffer in
            buffer.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
        }
        return (storage, info.pointee.ai_addrlen)
    }

    /// The host and port in a socket address, with an IPv4-mapped address
    /// given as plain IPv4.
    static func describe(_ storage: sockaddr_storage) -> (host: String, port: Int) {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let length = socklen_t(storage.ss_len)
        let status = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard status == 0 else { return ("", 0) }
        var text = String(cString: host)
        if text.hasPrefix("::ffff:"), text.contains(".") { text.removeFirst(7) }
        return (text, Int(String(cString: service)) ?? 0)
    }

    /// A listening socket on every IPv4 and IPv6 address, or -1.
    static func listener(port: UInt16, reusePort: Bool) -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        var off: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if reusePort { setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size)) }
        // Accepts IPv4 too.
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Accepts a connection, with the peer's address.
    static func accept(_ serverFD: Int32) -> (fd: Int32, host: String, port: Int)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let fd = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(serverFD, $0, &length) }
        }
        guard fd >= 0 else { return nil }
        let peer = describe(storage)
        return (fd, peer.host, peer.port)
    }
}
