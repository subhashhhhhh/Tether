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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tether", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let p12URL = appSupport.appendingPathComponent("identity.p12")
        let certURL = appSupport.appendingPathComponent("certificate.pem")
        let keyURL = appSupport.appendingPathComponent("key.pem")

        // Migration from previous KDEConnect installation if available
        let oldAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KDEConnect", isDirectory: true)
        let oldCertURL = oldAppSupport.appendingPathComponent("certificate.pem")
        let oldKeyURL = oldAppSupport.appendingPathComponent("key.pem")
        let oldId = UserDefaults.standard.string(forKey: "kdeconnect_device_id")

        if !FileManager.default.fileExists(atPath: keyURL.path) &&
           FileManager.default.fileExists(atPath: oldKeyURL.path) &&
           FileManager.default.fileExists(atPath: oldCertURL.path) {
            try? FileManager.default.copyItem(at: oldCertURL, to: certURL)
            try? FileManager.default.copyItem(at: oldKeyURL, to: keyURL)
            Self.exportPKCS12(keyURL: keyURL, certURL: certURL, p12URL: p12URL)
            if let oldId = oldId {
                UserDefaults.standard.set(oldId, forKey: "tether_device_id")
            }
        }

        var id = UserDefaults.standard.string(forKey: "tether_device_id")
        var name = UserDefaults.standard.string(forKey: "tether_device_name")
            ?? UserDefaults.standard.string(forKey: "kdeconnect_device_name")
            ?? Host.current().localizedName ?? "Mac"

        let p12Exists = FileManager.default.fileExists(atPath: p12URL.path)

        if id == nil || !p12Exists {
            // Generate clean 32-character hexadecimal UUID
            let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            id = newId
            UserDefaults.standard.set(newId, forKey: "tether_device_id")
            UserDefaults.standard.set(name, forKey: "tether_device_name")

            Self.generateCertificates(deviceId: newId, p12URL: p12URL, certURL: certURL, keyURL: keyURL)
        }

        self.deviceId = id!
        self.deviceName = name

        // Get or create dedicated private keychain to avoid touching login.keychain
        let keychainURL = appSupport.appendingPathComponent("tether.keychain-db")
        let dedicatedKeychain = Self.getOrCreateKeychain(at: keychainURL)

        // Load PKCS12 into dedicated keychain
        let p12Data = (try? Data(contentsOf: p12URL)) ?? Data()
        var options: [CFString: Any] = [
            kSecImportExportPassphrase: "tether"
        ]
        if let kc = dedicatedKeychain {
            options[kSecImportExportKeychain] = kc
        }
        var items: CFArray?
        var status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        if status != errSecSuccess {
            options[kSecImportExportPassphrase] = "kdeconnect"
            status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        }

        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] as! SecIdentity? else {
            fatalError("Failed to import Tether SecIdentity from PKCS12: \(status)")
        }

        self.secIdentity = identity

        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        self.secCertificate = certRef!

        // Resolve the private key once, here, so the cost of locating it in the
        // keychain is not paid in the middle of a TLS handshake.
        var privateKey: SecKey?
        if SecIdentityCopyPrivateKey(identity, &privateKey) != errSecSuccess || privateKey == nil {
            fatalError("Failed to resolve the Tether identity's private key from the keychain")
        }

        // Read PEM
        self.certificatePEM = (try? String(contentsOf: certURL, encoding: .utf8)) ?? ""

        // Calculate SHA-256 fingerprint
        let certData = SecCertificateCopyData(self.secCertificate) as Data
        let digest = SHA256.hash(data: certData)
        self.certificateFingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func getOrCreateKeychain(at url: URL) -> SecKeychain? {
        var keychain: SecKeychain?
        let path = url.path
        let password = "tether"
        let passLen = UInt32(password.utf8.count)

        if FileManager.default.fileExists(atPath: path) {
            if SecKeychainOpen(path, &keychain) == errSecSuccess, let kc = keychain {
                SecKeychainUnlock(kc, passLen, password, true)
                var settings = SecKeychainSettings(
                    version: 1,
                    lockOnSleep: DarwinBoolean(false),
                    useLockInterval: DarwinBoolean(false),
                    lockInterval: 0
                )
                SecKeychainSetSettings(kc, &settings)
                return kc
            }
        }

        // Save existing user search list before creating to prevent polluting global keychain list
        var originalSearchList: CFArray?
        SecKeychainCopyDomainSearchList(.user, &originalSearchList)

        let status = SecKeychainCreate(path, passLen, password, false, nil, &keychain)
        if status == errSecSuccess, let kc = keychain {
            SecKeychainUnlock(kc, passLen, password, true)
            var settings = SecKeychainSettings(
                version: 1,
                lockOnSleep: DarwinBoolean(false),
                useLockInterval: DarwinBoolean(false),
                lockInterval: 0
            )
            SecKeychainSetSettings(kc, &settings)

            // Restore domain search list so this dedicated keychain never prompts system-wide
            if let list = originalSearchList {
                SecKeychainSetDomainSearchList(.user, list)
            }
            return kc
        }
        return nil
    }

    private static func exportPKCS12(keyURL: URL, certURL: URL, p12URL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = """
        openssl pkcs12 -export -in "\(certURL.path)" -inkey "\(keyURL.path)" -out "\(p12URL.path)" -passout pass:tether
        """
        process.arguments = ["-c", script]
        try? process.run()
        process.waitUntilExit()
    }

    private static func generateCertificates(deviceId: String, p12URL: URL, certURL: URL, keyURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")

        let script = """
        openssl ecparam -name prime256v1 -genkey -noout -out "\(keyURL.path)" && \
        chmod 600 "\(keyURL.path)" && \
        openssl req -new -x509 -key "\(keyURL.path)" -out "\(certURL.path)" -days 3650 -subj "/CN=\(deviceId)/O=KDE/OU=KDE Connect" && \
        openssl pkcs12 -export -in "\(certURL.path)" -inkey "\(keyURL.path)" -out "\(p12URL.path)" -passout pass:tether
        """
        process.arguments = ["-c", script]

        try? process.run()
        process.waitUntilExit()
    }

    public func createSecIdentityProtocol() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }

    public func toDeviceInfo(tcpPort: Int = 1716) -> DeviceInfo {
        DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: .laptop,
            protocolVersion: NetworkPacket.protocolVersion,
            incomingCapabilities: DeviceInfo.defaultIncomingCapabilities,
            outgoingCapabilities: DeviceInfo.defaultOutgoingCapabilities,
            tcpPort: tcpPort
        )
    }
}

