//
//  SocketTLS.swift
//  Tether
//
//  Shared helpers for the SecureTransport-over-BSD-socket stack used by both the
//  packet connection and payload transfers.
//
//  KDE Connect upgrades an already-open TCP stream to TLS after a plaintext
//  identity line, which Network.framework cannot express, so the raw socket and
//  SecureTransport stay. What these helpers change is how we wait: instead of
//  sleeping in a loop and hoping the socket is ready, we block in poll() until
//  the kernel says it is, bounded by an explicit deadline.
//

import Foundation
import Security
import Darwin
import CryptoKit

enum SocketTLS {
    /// Longest single poll() while re-driving a handshake.
    ///
    /// SecureTransport does not say whether a would-block handshake step is
    /// waiting to read or to write. Reads are by far the common case, so we wait
    /// for readability but cap each wait so a pending write is retried promptly.
    private static let handshakeStepWait: TimeInterval = 0.05

    /// Blocks until `fd` reports any of `events` or `deadline` passes.
    ///
    /// - Returns: `true` if the socket became ready, `false` on timeout or error.
    @discardableResult
    static func wait(fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }

            var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = Darwin.poll(&pfd, 1, Int32(min(remaining, 3600) * 1000))
            if result > 0 { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
    }

    /// Drives `SSLHandshake` to completion, sleeping in poll() between steps.
    ///
    /// Peer authentication is deliberately left to the caller: KDE Connect peers
    /// use self-signed certificates that are pinned by fingerprint after the
    /// handshake, so `errSSLPeerAuthCompleted` / `errSSLClientCertRequested` are
    /// simply stepped past here.
    static func handshake(_ ctx: SSLContext, fd: Int32, deadline: Date) -> OSStatus {
        var status: OSStatus = errSSLWouldBlock
        while status == errSSLWouldBlock
            || status == errSSLPeerAuthCompleted
            || status == errSSLClientCertRequested {
            guard Date() < deadline else { return errSSLWouldBlock }

            status = SSLHandshake(ctx)
            if status == errSSLWouldBlock {
                let stepDeadline = min(deadline, Date().addingTimeInterval(handshakeStepWait))
                wait(fd: fd, for: POLLIN, until: stepDeadline)
            }
        }
        return status
    }

    /// Writes the whole buffer to the socket or fails; never returns having
    /// written part of it.
    ///
    /// A short write on a framed stream corrupts every packet after it, so a
    /// non-`noErr` result means the connection must be torn down.
    ///
    /// When the socket buffer fills, SecureTransport accepts the rest of the
    /// data into its own buffer and returns `errSSLWouldBlock` with the full
    /// byte count. Those bytes have not reached the socket yet, so keep calling
    /// `SSLWrite` with no new data until it reports `noErr`. Closing before that
    /// silently drops them (a file arrived cut off at the 128 KB socket buffer).
    static func writeAll(_ ctx: SSLContext, fd: Int32, _ data: Data, deadline: Date) -> OSStatus {
        var status: OSStatus = noErr
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                var written = 0
                status = SSLWrite(ctx, ptr, remaining, &written)
                if written > 0 {
                    remaining -= written
                    ptr = ptr.advanced(by: written)
                }
                if status == errSSLWouldBlock {
                    guard wait(fd: fd, for: POLLOUT, until: deadline) else { return }
                    continue
                }
                if status != noErr { return }
            }
        }
        guard status == noErr || status == errSSLWouldBlock else { return status }

        // Flush whatever SecureTransport is still holding.
        while status == errSSLWouldBlock {
            guard wait(fd: fd, for: POLLOUT, until: deadline) else { return errSSLWouldBlock }
            var written = 0
            status = SSLWrite(ctx, nil, 0, &written)
        }
        return status
    }

    /// Ends a connection without losing data still in flight: sends TLS
    /// close_notify, half-closes, and waits briefly for the peer to finish
    /// reading and close its side. Closing outright can reset the connection
    /// and discard bytes the peer hasn't read yet.
    static func closeGracefully(_ ctx: SSLContext, fd: Int32, timeout: TimeInterval = 5) {
        SSLClose(ctx)
        Darwin.shutdown(fd, SHUT_WR)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while wait(fd: fd, for: POLLIN, until: deadline) {
            if Darwin.read(fd, &buffer, buffer.count) <= 0 { break }
        }
    }

    /// Notices within about 35 seconds that a phone has vanished without
    /// closing the connection (Wi-Fi turned off, out of range), so it stops
    /// showing as connected. macOS's defaults take minutes: a probe every 75 s,
    /// 8 times. Probes are only sent while nothing else is flowing, and the
    /// phone's kernel answers them without waking KDE Connect.
    ///
    /// It can't be much shorter. A phone with its screen off parks its Wi-Fi
    /// radio between beacons and can take several seconds to answer anything
    /// (9 s measured on a Pixel 9), so a tighter window drops a phone that is
    /// only asleep, and the notifications that arrive before it reconnects.
    static func detectDeadPeerQuickly(_ fd: Int32) {
        func set(_ level: Int32, _ option: Int32, _ value: Int32) {
            var value = value
            setsockopt(fd, level, option, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(IPPROTO_TCP, TCP_KEEPALIVE, 10)  // idle seconds before the first probe
        set(IPPROTO_TCP, TCP_KEEPINTVL, 5)   // seconds between probes
        set(IPPROTO_TCP, TCP_KEEPCNT, 5)     // unanswered probes before giving up
        // Keepalive is suspended while sent data is unacknowledged; without this,
        // retransmitting to a vanished phone would keep the connection for minutes.
        set(IPPROTO_TCP, TCP_RXT_CONNDROPTIME, 35)
    }

    /// SHA-256 fingerprint of the peer's leaf certificate, lowercase hex with colons.
    static func peerFingerprint(_ ctx: SSLContext) -> String? {
        var trust: SecTrust?
        guard SSLCopyPeerTrust(ctx, &trust) == noErr, let trust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return fingerprint(of: leaf)
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Fingerprints are compared case-insensitively: older builds stored them in
    /// mixed case. An empty stored value never matches.
    static func fingerprintsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

// MARK: - Untrusted file names

enum SafeFilename {
    /// Reduces a peer-supplied name to a single path component that cannot
    /// escape the directory it is joined to.
    static func sanitize(_ raw: String?, fallback: String = "ReceivedFile") -> String {
        let candidate = (raw ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .last { !$0.isEmpty } ?? ""

        var name = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        // A leading dot would hide the file; "." and ".." would point elsewhere.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return fallback }

        // Keep under the 255-byte APFS component limit, preserving the extension.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = String((name as NSString).deletingPathExtension.prefix(150))
            name = ext.isEmpty ? base : "\(base).\(ext.prefix(20))"
        }
        return name
    }

    /// Joins `filename` (sanitised) to `directory`, appending " (n)" until unused.
    static func uniqueURL(in directory: URL, for filename: String) -> URL {
        let clean = sanitize(filename)
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension

        var target = directory.appendingPathComponent(clean, isDirectory: false)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            target = directory.appendingPathComponent(name, isDirectory: false)
            counter += 1
        }

        // Belt and braces: the resolved path must still live in `directory`.
        let parent = target.deletingLastPathComponent().standardizedFileURL.path
        guard parent == directory.standardizedFileURL.path else {
            return directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        }
        return target
    }
}
