//
//  DeviceIdentity.swift
//  Tether
//

import Foundation
import Security
import Network
import CryptoKit

public final class DeviceIdentity: @unchecked Sendable {
    public static let shared = DeviceIdentity()

    public let deviceId: String
    public var deviceName: String
    public let certificateFingerprint: String
    public let certificatePEM: String
    public let secIdentity: SecIdentity
    public let secCertificate: SecCertificate

    /// TCP port we advertise in identity packets. Updated by the listener once it
    /// has bound, since 1716 may be taken and it then walks up to 1764.
    public var advertisedTCPPort: Int {
        get { portLock.withLock { tcpPort } }
        set { portLock.withLock { tcpPort = newValue } }
    }
    private let portLock = NSLock()
    private var tcpPort = 1716

    /// PKCS#12 passwords used by builds before 1.3. Only tried so an existing
    /// identity can be re-wrapped with a per-install passphrase.
    private static let legacyPassphrases = ["tether", "kdeconnect"]

    private struct Paths {
        let directory: URL
        let p12: URL
        let cert: URL
        let key: URL
        let passphrase: URL

        init(directory: URL) {
            self.directory = directory
            p12 = directory.appendingPathComponent("identity.p12")
            cert = directory.appendingPathComponent("certificate.pem")
            key = directory.appendingPathComponent("key.pem")
            passphrase = directory.appendingPathComponent("identity.pass")
        }

        var all: [URL] { [p12, cert, key, passphrase] }
    }

    private init() {
        let fm = FileManager.default
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let paths = Paths(directory: appSupportRoot.appendingPathComponent("Tether", isDirectory: true))

        try? fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directory.path)

        // Migration from previous KDEConnect installation if available
        let oldAppSupport = appSupportRoot.appendingPathComponent("KDEConnect", isDirectory: true)
        let oldCertURL = oldAppSupport.appendingPathComponent("certificate.pem")
        let oldKeyURL = oldAppSupport.appendingPathComponent("key.pem")

        if !fm.fileExists(atPath: paths.key.path),
           fm.fileExists(atPath: oldKeyURL.path),
           fm.fileExists(atPath: oldCertURL.path) {
            try? fm.copyItem(at: oldCertURL, to: paths.cert)
            try? fm.copyItem(at: oldKeyURL, to: paths.key)
            Self.exportPKCS12(paths: paths, passphrase: Self.storedOrNewPassphrase(paths: paths))
            if let oldId = UserDefaults.standard.string(forKey: "kdeconnect_device_id") {
                UserDefaults.standard.set(oldId, forKey: "tether_device_id")
            }
        }

        var id = UserDefaults.standard.string(forKey: "tether_device_id")
        let name = UserDefaults.standard.string(forKey: "tether_device_name")
            ?? UserDefaults.standard.string(forKey: "kdeconnect_device_name")
            ?? Host.current().localizedName ?? "Mac"

        if id == nil || !fm.fileExists(atPath: paths.p12.path) {
            id = Self.generateIdentity(paths: paths, deviceName: name)
        }

        // Remove any legacy on-disk keychain that caused password prompts
        try? fm.removeItem(at: paths.directory.appendingPathComponent("tether.keychain-db"))

        var identity = Self.importIdentity(paths: paths)
        if identity == nil {
            // The identity on disk is unreadable (corrupt file, lost passphrase).
            // Set it aside and start over rather than crashing on every launch.
            // Peers will see a new device and need to pair again.
            TetherLog("[DeviceIdentity] Stored identity could not be imported; generating a new one")
            Self.quarantine(paths: paths)
            id = Self.generateIdentity(paths: paths, deviceName: name)
            identity = Self.importIdentity(paths: paths)
        }

        guard let identity else {
            fatalError("Tether could not create a TLS identity. Check that /usr/bin/openssl exists and ~/Library/Application Support/Tether is writable.")
        }

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let certRef else {
            fatalError("Tether identity has no certificate")
        }

        self.deviceId = id!
        self.deviceName = name
        self.secIdentity = identity
        self.secCertificate = certRef
        self.certificatePEM = (try? String(contentsOf: paths.cert, encoding: .utf8)) ?? ""
        self.certificateFingerprint = SocketTLS.fingerprint(of: certRef).uppercased()
    }

    // MARK: - Identity storage

    /// Imports the PKCS#12 bundle, upgrading a legacy fixed-password bundle to
    /// the per-install passphrase on the way. Returns nil if nothing works.
    private static func importIdentity(paths: Paths) -> SecIdentity? {
        guard let p12Data = try? Data(contentsOf: paths.p12) else { return nil }

        let stored = try? String(contentsOf: paths.passphrase, encoding: .utf8)
        let candidates = [stored].compactMap { $0 } + legacyPassphrases

        for passphrase in candidates {
            guard let identity = importPKCS12(p12Data, passphrase: passphrase) else { continue }

            if passphrase != stored {
                // Re-wrap with a random passphrase so the bundle is no longer
                // protected by a password shared by every install.
                let fresh = newPassphrase()
                if FileManager.default.fileExists(atPath: paths.key.path) {
                    exportPKCS12(paths: paths, passphrase: fresh)
                    // The bundle and its passphrase change together, or not
                    // at all: a new bundle with the old passphrase on disk
                    // couldn't be opened at the next launch.
                    let reopened = importPKCS12((try? Data(contentsOf: paths.p12)) ?? Data(), passphrase: fresh) != nil
                    if !reopened || !writePassphrase(fresh, paths: paths) {
                        TetherLog("[DeviceIdentity] Couldn't re-wrap the identity; keeping the old one")
                        try? p12Data.write(to: paths.p12, options: .atomic)
                    }
                }
            }
            return identity
        }
        return nil
    }

    private static func importPKCS12(_ data: Data, passphrase: String) -> SecIdentity? {
        // Memory-only: the identity never touches the login keychain. Keys there
        // cost ~10s on their first signature in each process (securityd ACL work)
        // and ~90ms after, which stalled every TLS handshake and could push the
        // first connection past its timeout. In memory a signature takes well
        // under a millisecond, and there is nothing for macOS to prompt about.
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: passphrase,
            kSecImportToMemoryOnly: true
        ]

        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { return nil }
        let identity = value as! SecIdentity

        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, privateKey != nil else { return nil }
        return identity
    }

    /// Creates a fresh key, certificate and bundle, and returns the new device ID.
    private static func generateIdentity(paths: Paths, deviceName: String) -> String {
        let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let passphrase = newPassphrase()

        runOpenSSL("""
        openssl ecparam -name prime256v1 -genkey -noout -out "$KEY" && \
        chmod 600 "$KEY" && \
        openssl req -new -x509 -key "$KEY" -out "$CERT" -days 3650 -subj "/CN=\(newId)/O=KDE/OU=KDE Connect" && \
        openssl pkcs12 -export -in "$CERT" -inkey "$KEY" -out "$P12" -passout env:TETHER_P12_PASS
        """, paths: paths, passphrase: passphrase)

        writePassphrase(passphrase, paths: paths)
        restrictPermissions(paths: paths)
        UserDefaults.standard.set(newId, forKey: "tether_device_id")
        UserDefaults.standard.set(deviceName, forKey: "tether_device_name")
        return newId
    }

    private static func exportPKCS12(paths: Paths, passphrase: String) {
        runOpenSSL(
            #"openssl pkcs12 -export -in "$CERT" -inkey "$KEY" -out "$P12" -passout env:TETHER_P12_PASS"#,
            paths: paths,
            passphrase: passphrase
        )
        restrictPermissions(paths: paths)
    }

    /// Runs an openssl script with paths and the passphrase passed through the
    /// environment, so neither appears in the process list.
    private static func runOpenSSL(_ script: String, paths: Paths, passphrase: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "KEY": paths.key.path,
            "CERT": paths.cert.path,
            "P12": paths.p12.path,
            "TETHER_P12_PASS": passphrase
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            TetherLog("[DeviceIdentity] openssl failed to launch: \(error)")
        }
    }

    private static func storedOrNewPassphrase(paths: Paths) -> String {
        if let stored = try? String(contentsOf: paths.passphrase, encoding: .utf8), !stored.isEmpty {
            return stored
        }
        let fresh = newPassphrase()
        if !writePassphrase(fresh, paths: paths) {
            TetherLog("[DeviceIdentity] Couldn't save the identity's passphrase")
        }
        return fresh
    }

    private static func newPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Still random, from the system's UUID source.
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
    }

    @discardableResult
    private static func writePassphrase(_ passphrase: String, paths: Paths) -> Bool {
        do {
            try Data(passphrase.utf8).write(to: paths.passphrase, options: .atomic)
        } catch {
            return false
        }
        restrictPermissions(paths: paths)
        return true
    }

    private static func restrictPermissions(paths: Paths) {
        for url in paths.all where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func quarantine(paths: Paths) {
        let stamp = Int(Date().timeIntervalSince1970)
        for url in paths.all where FileManager.default.fileExists(atPath: url.path) {
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).broken-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    public func createSecIdentityProtocol() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }

    public func toDeviceInfo(tcpPort: Int? = nil) -> DeviceInfo {
        DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: .laptop,
            protocolVersion: NetworkPacket.protocolVersion,
            incomingCapabilities: DeviceInfo.defaultIncomingCapabilities,
            outgoingCapabilities: DeviceInfo.defaultOutgoingCapabilities,
            tcpPort: tcpPort ?? advertisedTCPPort
        )
    }
}

